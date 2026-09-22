import DroidBridgeCore
import Foundation
import DroidBridgeShared

/// Assembles the B1 data plane: reads packets from the tunnel into the C engine, opens one relay
/// connection per TCP flow, bridges bytes both ways, and answers virtual DNS through the relay.
final class TunnelController: NSObject, EngineBridgeDelegate, RelayFlowDelegate, @unchecked Sendable {
    private let packetSource: PacketSource
    private let secret: Data
    private let relayHost: String
    private let relayPort: UInt16
    private let maximumFlows: UInt16
    private let engineFactory: (UInt16, EngineBridgeDelegate) -> PacketIngesting?

    private var packetIngester: PacketIngesting?
    private var engineBridge: EngineBridge?
    private let lifecycleLock = NSLock()
    private var isRunning = false
    private var lifecycleGeneration: UInt64 = 0
    private let flowsLock = NSLock()
    private var flows: [UInt32: RelayFlowConnection] = [:]
    private let dnsClient: RelayDNSClient

    init(
        packetSource: PacketSource,
        secret: Data,
        relayHost: String = "127.0.0.1",
        relayPort: UInt16 = 27183,
        maximumFlows: UInt16 = 128,
        engineFactory: @escaping (UInt16, EngineBridgeDelegate) -> PacketIngesting? = {
            EngineBridge(maximumFlows: $0, delegate: $1)
        }
    ) {
        self.packetSource = packetSource
        self.secret = secret
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.maximumFlows = maximumFlows
        self.engineFactory = engineFactory
        let host = relayHost, port = relayPort
        self.dnsClient = RelayDNSClient(secret: secret, transportFactory: { NWConnectionTransport(host: host, port: port) })
        super.init()
    }

    @discardableResult
    func start() -> Bool {
        let generation: UInt64? = lifecycleLock.withLock({
            guard !isRunning else { return nil }
            isRunning = true
            lifecycleGeneration &+= 1
            return lifecycleGeneration
        })
        guard let generation else { return false }

        let engine = engineFactory(maximumFlows, self)
        packetIngester = engine
        engineBridge = engine as? EngineBridge
        guard engine != nil else {
            lifecycleLock.withLock { isRunning = false }
            return false
        }
        readPackets(generation: generation)
        return true
    }

    func stop() {
        lifecycleLock.withLock {
            isRunning = false
            lifecycleGeneration &+= 1
        }
        flowsLock.withLock { flows.values.forEach { conn in Task { await conn.close() } }; flows.removeAll() }
        engineBridge?.stop()
        packetIngester = nil
        engineBridge = nil
    }

    var activeFlowCount: Int { engineBridge?.activeFlows ?? 0 }

    // MARK: - packet read loop

    private func readPackets(generation: UInt64) {
        guard lifecycleLock.withLock({ isRunning && lifecycleGeneration == generation }) else { return }
        packetSource.read { [weak self] packets in
            guard let self, self.lifecycleLock.withLock({
                self.isRunning && self.lifecycleGeneration == generation
            }) else { return }
            // schedule the next read before processing, to avoid receive stalls
            self.readPackets(generation: generation)
            for packet in packets { self.packetIngester?.ingest(packet) }
        }
    }

    // MARK: - EngineBridgeDelegate (called on the engine queue)

    func engineEmitPacket(_ data: Data) {
        packetSource.write([data])
    }

    func engineOpenFlow(_ flow: UInt32, dstIP: [UInt8], port: UInt16) {
        let host = dstIP.map { String($0) }.joined(separator: ".")
        let transport = NWConnectionTransport(host: relayHost, port: relayPort)
        let conn = RelayFlowConnection(flowId: flow, destination: .ipv4(host, port),
                                       secret: secret, transport: transport, delegate: self)
        flowsLock.withLock { flows[flow] = conn }
        Task {
            do { try await conn.start() }
            catch { self.engineBridge?.relayOpenFailed(flow) }
        }
    }

    func engineSendFlow(_ flow: UInt32, _ data: Data) -> Int {
        guard let conn = flowsLock.withLock({ flows[flow] }) else { return Int(DB_SEND_ERROR) }
        return conn.enqueueFromCore(data) ? data.count : Int(DB_SEND_AGAIN)
    }

    func engineCloseFlow(_ flow: UInt32, reason: Int) {
        if let conn = flowsLock.withLock({ flows.removeValue(forKey: flow) }) {
            Task { await conn.close() }
        }
    }

    func engineSendDNS(_ flow: UInt32, _ query: Data) {
        Task {
            if let response = try? await dnsClient.query(query) {
                engineBridge?.dnsResponse(flow, response)
            }
        }
    }

    // MARK: - RelayFlowDelegate (from RelayFlowConnection)

    func relayFlowOpened(_ flowId: UInt32) { engineBridge?.relayOpened(flowId) }
    /// The relay's refusal reason is the only signal that distinguishes a policy
    /// denial from cellular loss, a slot leak, or an unreachable destination, so
    /// it is logged rather than discarded.
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode) {
        NSLog("DroidBridge flow %u refused by relay: %@", flowId, String(describing: error))
        engineBridge?.relayOpenFailed(flowId)
    }
    func relayFlowReceived(_ flowId: UInt32, data: Data) { engineBridge?.relayData(flowId, data) }
    func relayFlowWritable(_ flowId: UInt32) { engineBridge?.relayWritable(flowId) }
    func relayFlowClosed(_ flowId: UInt32, isError: Bool) {
        engineBridge?.relayClosed(flowId, isError: isError)
        _ = flowsLock.withLock { flows.removeValue(forKey: flowId) }
    }
}
