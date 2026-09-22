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
    private let engineFactory: (EngineBridgeDelegate) -> PacketIngesting?

    private var packetIngester: PacketIngesting?
    private var engineBridge: EngineBridge?
    private let lifecycleLock = NSLock()
    private var isRunning = false
    private let flowsLock = NSLock()
    private var flows: [UInt32: RelayFlowConnection] = [:]
    private let dnsClient: RelayDNSClient

    init(
        packetSource: PacketSource,
        secret: Data,
        relayHost: String = "127.0.0.1",
        relayPort: UInt16 = 27183,
        engineFactory: @escaping (EngineBridgeDelegate) -> PacketIngesting? = { EngineBridge(delegate: $0) }
    ) {
        self.packetSource = packetSource
        self.secret = secret
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.engineFactory = engineFactory
        let host = relayHost, port = relayPort
        self.dnsClient = RelayDNSClient(secret: secret, transportFactory: { NWConnectionTransport(host: host, port: port) })
        super.init()
    }

    func start() {
        guard lifecycleLock.withLock({
            guard !isRunning else { return false }
            isRunning = true
            return true
        }) else { return }

        let engine = engineFactory(self)
        packetIngester = engine
        engineBridge = engine as? EngineBridge
        guard engine != nil else {
            lifecycleLock.withLock { isRunning = false }
            return
        }
        readPackets()
    }

    func stop() {
        lifecycleLock.withLock { isRunning = false }
        flowsLock.withLock { flows.values.forEach { conn in Task { await conn.close() } }; flows.removeAll() }
        packetIngester = nil
        engineBridge = nil
    }

    var activeFlowCount: Int { engineBridge?.activeFlows ?? 0 }

    // MARK: - packet read loop

    private func readPackets() {
        guard lifecycleLock.withLock({ isRunning }) else { return }
        packetSource.read { [weak self] packets in
            guard let self, self.lifecycleLock.withLock({ self.isRunning }) else { return }
            // schedule the next read before processing, to avoid receive stalls
            self.readPackets()
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
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode) { engineBridge?.relayOpenFailed(flowId) }
    func relayFlowReceived(_ flowId: UInt32, data: Data) { engineBridge?.relayData(flowId, data) }
    func relayFlowWritable(_ flowId: UInt32) { engineBridge?.relayWritable(flowId) }
    func relayFlowClosed(_ flowId: UInt32, isError: Bool) {
        engineBridge?.relayClosed(flowId, isError: isError)
        _ = flowsLock.withLock { flows.removeValue(forKey: flowId) }
    }
}
