import DroidBridgeCore
import Foundation
import NetworkExtension
import DroidBridgeShared

/// Assembles the B1 data plane: reads packets from the tunnel into the C engine, opens one relay
/// connection per TCP flow, bridges bytes both ways, and answers virtual DNS through the relay.
final class TunnelController: NSObject, EngineBridgeDelegate, RelayFlowDelegate, @unchecked Sendable {
    private let packetFlow: NEPacketTunnelFlow
    private let secret: Data
    private let relayHost: String
    private let relayPort: UInt16

    private var engine: EngineBridge?
    private let flowsLock = NSLock()
    private var flows: [UInt32: RelayFlowConnection] = [:]
    private let dnsClient: RelayDNSClient

    init(packetFlow: NEPacketTunnelFlow, secret: Data, relayHost: String = "127.0.0.1", relayPort: UInt16 = 27183) {
        self.packetFlow = packetFlow
        self.secret = secret
        self.relayHost = relayHost
        self.relayPort = relayPort
        let host = relayHost, port = relayPort
        self.dnsClient = RelayDNSClient(secret: secret, transportFactory: { NWConnectionTransport(host: host, port: port) })
        super.init()
    }

    func start() {
        engine = EngineBridge(delegate: self)
        readPackets()
    }

    func stop() {
        flowsLock.withLock { flows.values.forEach { conn in Task { await conn.close() } }; flows.removeAll() }
        engine = nil
    }

    var activeFlowCount: Int { engine?.activeFlows ?? 0 }

    // MARK: - packet read loop

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, protocols in
            guard let self else { return }
            // schedule the next read before processing, to avoid receive stalls
            self.readPackets()
            for (packet, proto) in zip(packets, protocols) where proto.int32Value == AF_INET {
                self.engine?.ingest(packet)
            }
        }
    }

    // MARK: - EngineBridgeDelegate (called on the engine queue)

    func engineEmitPacket(_ data: Data) {
        packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
    }

    func engineOpenFlow(_ flow: UInt32, dstIP: [UInt8], port: UInt16) {
        let host = dstIP.map { String($0) }.joined(separator: ".")
        let transport = NWConnectionTransport(host: relayHost, port: relayPort)
        let conn = RelayFlowConnection(flowId: flow, destination: .ipv4(host, port),
                                       secret: secret, transport: transport, delegate: self)
        flowsLock.withLock { flows[flow] = conn }
        Task {
            do { try await conn.start() }
            catch { self.engine?.relayOpenFailed(flow) }
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
                engine?.dnsResponse(flow, response)
            }
        }
    }

    // MARK: - RelayFlowDelegate (from RelayFlowConnection)

    func relayFlowOpened(_ flowId: UInt32) { engine?.relayOpened(flowId) }
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode) { engine?.relayOpenFailed(flowId) }
    func relayFlowReceived(_ flowId: UInt32, data: Data) { engine?.relayData(flowId, data) }
    func relayFlowWritable(_ flowId: UInt32) { engine?.relayWritable(flowId) }
    func relayFlowClosed(_ flowId: UInt32, isError: Bool) {
        engine?.relayClosed(flowId, isError: isError)
        _ = flowsLock.withLock { flows.removeValue(forKey: flowId) }
    }
}
