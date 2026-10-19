import DroidBridgeCore
import Foundation
import Darwin
import DroidBridgeShared
import os

/// Each start owns an independent session. Late I/O can only reach its original engine.
final class TunnelController: NSObject, @unchecked Sendable {
    private let packetSource: PacketSource
    private let secret: Data
    private let relayHost: String
    private let relayPort: UInt16
    private let maximumFlows: UInt16
    private let capabilityPollInterval: Duration
    private let transportFactory: @Sendable () -> any RelayTransport
    private let engineFactory: (UInt16, EngineBridgeDelegate) -> PacketIngesting?
    private let lock = NSLock()
    private var session: TunnelSession?
    init(packetSource: PacketSource, secret: Data, relayHost: String = "127.0.0.1", relayPort: UInt16 = 27183,
         maximumFlows: UInt16 = 128,
         transportFactory: (@Sendable () -> any RelayTransport)? = nil,
         capabilityPollInterval: Duration = .seconds(5),
         engineFactory: @escaping (UInt16, EngineBridgeDelegate) -> PacketIngesting? = { EngineBridge(maximumFlows: $0, delegate: $1) }) {
        self.packetSource = packetSource; self.secret = secret; self.relayHost = relayHost
        self.relayPort = relayPort; self.maximumFlows = maximumFlows; self.engineFactory = engineFactory
        self.capabilityPollInterval = capabilityPollInterval
        self.transportFactory = transportFactory ?? { NWConnectionTransport(host: relayHost, port: relayPort) }
    }
    @discardableResult func start() -> Bool {
        let created: TunnelSession? = lock.withLock {
            guard session == nil else { return nil }
            let candidate = TunnelSession(packetSource: packetSource, secret: secret, transportFactory: transportFactory,
                                          capabilityPollInterval: capabilityPollInterval)
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
    private var metricsSession: TunnelSession? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return session
    }
    var activeFlowCount: Int { metricsSession?.engine?.activeFlows ?? 0 }
    var activeUDPCount: Int { metricsSession?.engine?.activeUDP ?? 0 }
    var capabilities: RelayCapabilities? { metricsSession?.capabilities }
    var udpDrops: UInt64 { metricsSession?.udpDrops ?? 0 }
    var peerDatagramLimit: Int? { metricsSession?.peerDatagramLimit }
    private func readPackets(session captured: TunnelSession) {
        guard lock.withLock({ session === captured }) else { return }
        packetSource.read { [weak self, weak captured] packets in
            guard let self, let captured, self.lock.withLock({ self.session === captured }) else { return }
            self.readPackets(session: captured)
            for packet in packets { captured.ingester?.ingest(packet) }
        }
    }
}

private final class TunnelSession: EngineBridgeDelegate, RelayFlowDelegate, RelayDatagramDelegate, RelayUDPAssociationDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "io.droidbridge", category: "NetworkRetirement")
    let packetSource: PacketSource
    let secret: Data
    let transportFactory: @Sendable () -> any RelayTransport
    var ingester: PacketIngesting?
    var engine: EngineBridge?
    private let lock = NSLock()
    private var stopped = false
    private var flows: [UInt32: RelayFlowConnection] = [:]
    private var datagrams: [UInt32: RelayDatagramConnection] = [:]
    private var associations: [UUID: RelayUDPAssociationConnection] = [:]
    private var associationIndex = UDPAssociationIndex()
    private var networkEpoch: UInt64 = 0
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var retiredDrops: UInt64 = 0
    private var lastPeerLimit: Int?
    private var negotiated: RelayCapabilities?
    private var capabilityTask: Task<Void, Never>?
    private let dns: RelayDNSClient
    private let extensions: RelayExtensionClient
    private let capabilityPollInterval: Duration
    init(packetSource: PacketSource, secret: Data, transportFactory: @escaping @Sendable () -> any RelayTransport,
         capabilityPollInterval: Duration) {
        self.packetSource = packetSource; self.secret = secret; self.transportFactory = transportFactory
        self.capabilityPollInterval = capabilityPollInterval
        dns = RelayDNSClient(secret: secret, transportFactory: transportFactory)
        extensions = RelayExtensionClient(secret: secret, transportFactory: transportFactory)
    }
    var capabilities: RelayCapabilities? { lock.withLock { negotiated } }
    /// Latest, not smallest: an updated phone app clears the warning on its next UDP stream.
    var peerDatagramLimit: Int? { lock.withLock { lastPeerLimit } }
    private func notePeerLimit(_ limit: Int?) { if let limit { lock.withLock { lastPeerLimit = limit } } }
    var udpDrops: UInt64 {
        let local = lock.withLock { retiredDrops &+ datagrams.values.reduce(0) { $0 &+ $1.drops } &+ associations.values.reduce(0) { $0 &+ $1.drops } }
        return local &+ (engine?.udpDrops ?? 0) &+ (capabilities?.udpDrops ?? 0)
    }
    private var running: Bool { lock.withLock { !stopped } }
    func startCapabilities() {
        guard engine != nil else { return }
        capabilityTask = Task { [weak self] in
            var timeoutCount = 0
            while !Task.isCancelled {
                guard let self, self.running else { return }
                var delay = self.capabilityPollInterval
                do {
                    let caps = try await self.extensions.capabilities()
                    guard self.running, !Task.isCancelled else { return }
                    let changed = self.lock.withLock {
                        let changed = self.negotiated.map { $0.cellularGeneration != caps.cellularGeneration } ?? false
                        self.negotiated = caps; return changed
                    }
                    if changed { self.retireNetworkFlows(reason: "cellular-generation-changed") }
                    self.engine?.setCapabilities(caps)
                    if timeoutCount > 0 {
                        self.logger.info("Capabilities recovered after \(timeoutCount) timeouts; generationChanged=\(changed)")
                    }
                    timeoutCount = 0
                } catch {
                    guard self.running, !Task.isCancelled else { return }
                    if (error as? DroidBridgeError) == .relayTimedOut,
                       self.lock.withLock({ self.negotiated != nil }), timeoutCount < 3 {
                        timeoutCount += 1
                        delay = min(self.capabilityPollInterval, .seconds(1 << (timeoutCount - 1)))
                        self.logger.notice("Capabilities timeout: attempt=\(timeoutCount) action=retain")
                        do { try await Task.sleep(for: delay) } catch { return }
                        continue
                    }
                    self.engine?.blockCapabilities()
                    self.lock.withLock { self.negotiated = nil }
                    let reason: String
                    switch error {
                    case DroidBridgeError.relayTimedOut: reason = "capabilities-timeout"
                    case DroidBridgeError.relayAuthenticationFailed: reason = "capabilities-authentication"
                    case DroidBridgeError.relayProtocol: reason = "capabilities-protocol"
                    case is CancellationError: reason = "capabilities-cancelled"
                    default: reason = "capabilities-transport-error"
                    }
                    self.retireNetworkFlows(reason: reason)
                    timeoutCount = 0
                }
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
    }
    func stop() {
        lock.withLock { stopped = true }
        capabilityTask?.cancel(); capabilityTask = nil
        retireNetworkFlows(reason: "stop")
        engine?.stop()
    }
    private func retireNetworkFlows(reason: String) {
        let old = lock.withLock {
            networkEpoch &+= 1
            let old = (flows, datagrams, operations, associations, associationIndex.removeAll())
            retiredDrops &+= datagrams.values.reduce(0) { $0 &+ $1.drops } &+ associations.values.reduce(0) { $0 &+ $1.drops }
            flows.removeAll(); datagrams.removeAll(); operations.removeAll(); associations.removeAll()
            return old
        }
        // Fixed cause labels and counts only; never log peer addresses or session secrets.
        logger.info("Retiring network flows: reason=\(reason, privacy: .public) tcp=\(old.0.count) legacyUDP=\(old.1.count) associations=\(old.3.count)")
        old.2.values.forEach { $0.cancel() }
        for (id, conn) in old.0 { engine?.relayClosed(id, isError: true); Task { await conn.close() } }
        for (id, conn) in old.1 { engine?.udpClosed(id); Task { await conn.close() } }
        for id in old.4 { engine?.udpClosed(id) }
        for conn in old.3.values { Task { await conn.close() } }
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
        let conn = RelayFlowConnection(flowId: flow, destination: destination, secret: secret, transport: transportFactory(), delegate: self)
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
        if reason == Int(DB_CLOSE_NORMAL.rawValue) || reason == Int(DB_CLOSE_COMPLETE.rawValue) {
            lock.withLock { flows[flow] }?.finishSending()
            return
        }
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
    func engineOpenUDP(_ flow: UInt32, dstIP: [UInt8], port: UInt16, sourcePort: UInt16, sourceIP: [UInt8]) {
        if sourcePort != 0, lock.withLock({ negotiated?.supports(.udpAssociation) == true }) {
            guard let peer = try? UDPAssociationPeer(address: Data(dstIP), port: port) else { engine?.udpClosed(flow); return }
            let accepted = lock.withLock { () -> Bool in
                guard !stopped else { return false }
                let attached = associationIndex.attach(flow: flow, sourcePort: sourcePort, peer: peer, sourceAddress: Data(sourceIP))
                if attached.created {
                    let conn = RelayUDPAssociationConnection(token: attached.token, family: peer.family, secret: secret,
                        transport: transportFactory(), delegate: self)
                    associations[attached.token] = conn
                    conn.register(flow: flow, peer: peer)
                    Task { // Failure closes through the token-scoped delegate.
                        if (try? await conn.start()) != nil { self.notePeerLimit(await conn.peerLimit) }
                    }
                } else { associations[attached.token]?.register(flow: flow, peer: peer) }
                return true
            }
            if !accepted { engine?.udpClosed(flow) }
            return
        }
        guard let destination = destination(dstIP, port: port), running else { engine?.udpClosed(flow); return }
        let conn = RelayDatagramConnection(flowId: flow, destination: destination, secret: secret, transport: transportFactory(), delegate: self)
        let accepted = lock.withLock { guard !stopped else { return false }; datagrams[flow] = conn; return true }
        guard accepted else { return }
        Task {
            do { try await conn.start(); self.notePeerLimit(await conn.peerLimit) } catch { self.engine?.udpClosed(flow) }
        }
    }
    func engineSendUDP(_ flow: UInt32, _ data: Data) {
        lock.withLock {
            if let binding = associationIndex.binding(flow: flow) {
                associations[binding.token]?.enqueueFromCore(flow: flow, data: data)
            } else { datagrams[flow]?.enqueueFromCore(data) }
        }
    }
    func engineCloseUDP(_ flow: UInt32) {
        let association = lock.withLock { () -> RelayUDPAssociationConnection? in
            guard let removed = associationIndex.detach(flow: flow) else { return nil }
            let conn = associations[removed.token]
            conn?.remove(flow: flow)
            guard removed.last else { return nil }
            retiredDrops &+= conn?.drops ?? 0
            associations.removeValue(forKey: removed.token)
            return conn
        }
        if let association { Task { await association.close() } }
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
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode) {
        engine?.relayOpenFailed(flowId)
        engineCloseFlow(flowId, reason: Int(DB_CLOSE_RESET.rawValue))
    }
    func relayFlowReceived(_ flowId: UInt32, data: Data) async -> Bool {
        guard running, let engine else { return false }
        return await engine.relayData(flowId, data)
    }
    func relayFlowWritable(_ flowId: UInt32) { if running { engine?.relayWritable(flowId) } }
    func relayFlowReadEOF(_ flowId: UInt32) { if running { engine?.relayClosed(flowId, isError: false) } }
    func relayFlowClosed(_ flowId: UInt32, isError: Bool) { engine?.relayClosed(flowId, isError: isError); _ = lock.withLock { flows.removeValue(forKey: flowId) } }
    func relayUDPAssociationReceived(_ token: UUID, peer: UDPAssociationPeer, data: Data) async {
        let flow = lock.withLock { stopped ? nil : associationIndex.flow(token: token, peer: peer) }
        if let flow { await engine?.udpData(flow, data) }
    }
    func relayUDPAssociationClosed(_ token: UUID) {
        let retired = lock.withLock {
            let conn = associations.removeValue(forKey: token)
            retiredDrops &+= conn?.drops ?? 0
            return associationIndex.remove(token: token)
        }
        for flow in retired { engine?.udpClosed(flow) }
    }
    func relayDatagramReceived(_ flow: UInt32, data: Data) async { if running { await engine?.udpData(flow, data) } }
    func relayDatagramClosed(_ flow: UInt32) { engine?.udpClosed(flow); engineCloseUDP(flow) }
}
