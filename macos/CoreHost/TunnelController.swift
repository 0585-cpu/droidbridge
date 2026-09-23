import DroidBridgeCore
import Foundation
import Darwin
import DroidBridgeShared

/// Each start owns an independent session. Late I/O can only reach its original engine.
final class TunnelController: NSObject, @unchecked Sendable {
    private let packetSource: PacketSource
    private let secret: Data
    private let relayHost: String
    private let relayPort: UInt16
    private let maximumFlows: UInt16
    private let engineFactory: (UInt16, EngineBridgeDelegate) -> PacketIngesting?
    private let lock = NSLock()
    private var session: TunnelSession?
    init(packetSource: PacketSource, secret: Data, relayHost: String = "127.0.0.1", relayPort: UInt16 = 27183,
         maximumFlows: UInt16 = 128,
         engineFactory: @escaping (UInt16, EngineBridgeDelegate) -> PacketIngesting? = { EngineBridge(maximumFlows: $0, delegate: $1) }) {
        self.packetSource = packetSource; self.secret = secret; self.relayHost = relayHost
        self.relayPort = relayPort; self.maximumFlows = maximumFlows; self.engineFactory = engineFactory
    }
    @discardableResult func start() -> Bool {
        let created: TunnelSession? = lock.withLock {
            guard session == nil else { return nil }
            let candidate = TunnelSession(packetSource: packetSource, secret: secret, host: relayHost, port: relayPort)
            guard let ingester = engineFactory(maximumFlows, candidate) else { return nil }
            candidate.ingester = ingester; candidate.engine = ingester as? EngineBridge
            session = candidate
            return candidate
        }
        guard let created else { return false }
        created.startCapabilities()
        readPackets(session: created)
        return true
    }
    func stop() {
        lock.withLock {
            let old = session; session = nil
            // The C stack has process-global lwIP state; destruction must precede any restart.
            old?.stop()
        }
    }
    var activeFlowCount: Int { lock.withLock { session }?.engine?.activeFlows ?? 0 }
    var activeUDPCount: Int { lock.withLock { session }?.engine?.activeUDP ?? 0 }
    var capabilities: RelayCapabilities? { lock.withLock { session }?.capabilities }
    var udpDrops: UInt64 { lock.withLock { session }?.udpDrops ?? 0 }
    private func readPackets(session captured: TunnelSession) {
        guard lock.withLock({ session === captured }) else { return }
        packetSource.read { [weak self, weak captured] packets in
            guard let self, let captured, self.lock.withLock({ self.session === captured }) else { return }
            self.readPackets(session: captured)
            for packet in packets { captured.ingester?.ingest(packet) }
        }
    }
}

private final class TunnelSession: EngineBridgeDelegate, RelayFlowDelegate, RelayDatagramDelegate, @unchecked Sendable {
    let packetSource: PacketSource
    let secret: Data
    let host: String
    let port: UInt16
    var ingester: PacketIngesting?
    var engine: EngineBridge?
    private let lock = NSLock()
    private var stopped = false
    private var flows: [UInt32: RelayFlowConnection] = [:]
    private var datagrams: [UInt32: RelayDatagramConnection] = [:]
    private var networkEpoch: UInt64 = 0
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var retiredDrops: UInt64 = 0
    private var negotiated: RelayCapabilities?
    private var capabilityTask: Task<Void, Never>?
    private let dns: RelayDNSClient
    private let extensions: RelayExtensionClient
    init(packetSource: PacketSource, secret: Data, host: String, port: UInt16) {
        self.packetSource = packetSource; self.secret = secret; self.host = host; self.port = port
        dns = RelayDNSClient(secret: secret, transportFactory: { NWConnectionTransport(host: host, port: port) })
        extensions = RelayExtensionClient(secret: secret, transportFactory: { NWConnectionTransport(host: host, port: port) })
    }
    var capabilities: RelayCapabilities? { lock.withLock { negotiated } }
    var udpDrops: UInt64 {
        let local = lock.withLock { retiredDrops &+ datagrams.values.reduce(0) { $0 &+ $1.drops } }
        return local &+ (engine?.udpDrops ?? 0) &+ (capabilities?.udpDrops ?? 0)
    }
    private var running: Bool { lock.withLock { !stopped } }
    func startCapabilities() {
        guard engine != nil else { return }
        capabilityTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.running else { return }
                do {
                    let caps = try await self.extensions.capabilities()
                    guard self.running, !Task.isCancelled else { return }
                    let changed = self.lock.withLock {
                        let changed = self.negotiated.map { $0.cellularGeneration != caps.cellularGeneration } ?? false
                        self.negotiated = caps; return changed
                    }
                    if changed { self.retireNetworkFlows() }
                    self.engine?.setCapabilities(caps)
                } catch {
                    guard self.running else { return }
                    self.engine?.blockCapabilities()
                    self.lock.withLock { self.negotiated = nil }
                    self.retireNetworkFlows()
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func stop() {
        lock.withLock { stopped = true }
        capabilityTask?.cancel(); capabilityTask = nil
        retireNetworkFlows()
        engine?.stop()
    }
    private func retireNetworkFlows() {
        let old = lock.withLock {
            networkEpoch &+= 1
            let old = (flows, datagrams, operations)
            retiredDrops &+= datagrams.values.reduce(0) { $0 &+ $1.drops }
            flows.removeAll(); datagrams.removeAll(); operations.removeAll()
            return old
        }
        old.2.values.forEach { $0.cancel() }
        for (id, conn) in old.0 { engine?.relayClosed(id, isError: true); Task { await conn.close() } }
        for (id, conn) in old.1 { engine?.udpClosed(id); Task { await conn.close() } }
    }
    private func destination(_ bytes: [UInt8], port: UInt16) -> OpenDestination? {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard bytes.withUnsafeBytes({ inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }) != nil else { return nil }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return bytes.count == 4 ? .ipv4(text, port) : .ipv6(text, port)
    }
    func engineEmitPacket(_ data: Data) { if running { packetSource.write([data]) } }
    func engineOpenFlow(_ flow: UInt32, dstIP: [UInt8], port: UInt16) {
        guard let destination = destination(dstIP, port: port), running else { engine?.relayOpenFailed(flow); return }
        let conn = RelayFlowConnection(flowId: flow, destination: destination, secret: secret, transport: NWConnectionTransport(host: host, port: self.port), delegate: self)
        let accepted = lock.withLock { guard !stopped else { return false }; flows[flow] = conn; return true }
        guard accepted else { return }
        let original = engine
        Task {
            do { try await conn.start() }
            catch { await conn.close(); original?.relayOpenFailed(flow); _ = self.lock.withLock { self.flows.removeValue(forKey: flow) } }
        }
    }
    func engineSendFlow(_ flow: UInt32, _ data: Data) -> Int {
        guard let conn = lock.withLock({ flows[flow] }) else { return Int(DB_SEND_ERROR) }
        return conn.enqueueFromCore(data) ? data.count : Int(DB_SEND_AGAIN)
    }
    func engineCloseFlow(_ flow: UInt32, reason: Int) {
        if let conn = lock.withLock({ flows.removeValue(forKey: flow) }) { Task { await conn.close() } }
    }
    private func launchOperation(_ action: @escaping @Sendable (EngineBridge, UInt64) async -> Void) {
        guard let engine else { return }
        let id = UUID()
        lock.withLock {
            guard !stopped else { return }
            let epoch = networkEpoch
            operations[id] = Task { [weak self] in
                await action(engine, epoch)
                _ = self?.lock.withLock { self?.operations.removeValue(forKey: id) }
            }
        }
    }
    private func deliver(epoch: UInt64, _ body: () -> Void) {
        lock.withLock {
            guard !stopped, epoch == networkEpoch else { return }
            body()
        }
    }
    func engineSendDNS(_ flow: UInt32, _ query: Data) {
        launchOperation { [self] original, epoch in
            if let response = try? await dns.query(query) {
                deliver(epoch: epoch) { original.dnsResponse(flow, response) }
            }
        }
    }
    func engineOpenUDP(_ flow: UInt32, dstIP: [UInt8], port: UInt16) {
        guard let destination = destination(dstIP, port: port), running else { engine?.udpClosed(flow); return }
        let conn = RelayDatagramConnection(flowId: flow, destination: destination, secret: secret, transport: NWConnectionTransport(host: host, port: self.port), delegate: self)
        let accepted = lock.withLock { guard !stopped else { return false }; datagrams[flow] = conn; return true }
        guard accepted else { return }
        Task { do { try await conn.start() } catch { self.engine?.udpClosed(flow) } }
    }
    func engineSendUDP(_ flow: UInt32, _ data: Data) { lock.withLock { datagrams[flow] }?.enqueueFromCore(data) }
    func engineCloseUDP(_ flow: UInt32) {
        let conn = lock.withLock { let conn = datagrams.removeValue(forKey: flow); retiredDrops &+= conn?.drops ?? 0; return conn }
        if let conn { Task { await conn.close() } }
    }
    func engineSendICMP(_ request: UInt32, family: UInt8, dstIP: Data, ttl: UInt8, payload: Data) {
        launchOperation { [self] original, epoch in
            do {
                let response = try await extensions.echo(request: request, family: family, destination: dstIP, ttl: ttl, payload: payload)
                deliver(epoch: epoch) { original.icmpResponse(request, response) }
            } catch { deliver(epoch: epoch) { original.icmpFailed(request) } }
        }
    }
    func relayFlowOpened(_ flowId: UInt32) { if running { engine?.relayOpened(flowId) } }
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode) { engine?.relayOpenFailed(flowId); engineCloseFlow(flowId, reason: 0) }
    func relayFlowReceived(_ flowId: UInt32, data: Data) { if running { engine?.relayData(flowId, data) } }
    func relayFlowWritable(_ flowId: UInt32) { if running { engine?.relayWritable(flowId) } }
    func relayFlowClosed(_ flowId: UInt32, isError: Bool) { engine?.relayClosed(flowId, isError: isError); _ = lock.withLock { flows.removeValue(forKey: flowId) } }
    func relayDatagramReceived(_ flow: UInt32, data: Data) async { if running { await engine?.udpData(flow, data) } }
    func relayDatagramClosed(_ flow: UInt32) { engine?.udpClosed(flow); engineCloseUDP(flow) }
}
