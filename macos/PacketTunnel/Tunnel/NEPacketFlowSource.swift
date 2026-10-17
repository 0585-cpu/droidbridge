import Darwin
import DroidBridgeShared
import Foundation
import NetworkExtension

/// Adapts NetworkExtension packet flow to the raw-IPv4 PacketSource contract.
final class NEPacketFlowSource: PacketSource {
    private let flow: NEPacketTunnelFlow

    init(_ flow: NEPacketTunnelFlow) {
        self.flow = flow
    }

    func read(_ handler: @escaping @Sendable ([Data]) -> Void) {
        flow.readPackets { packets, protocols in
            let ipv4 = zip(packets, protocols).compactMap { packet, addressFamily in
                (addressFamily.int32Value == AF_INET || addressFamily.int32Value == AF_INET6) ? packet : nil
            }
            handler(ipv4)
        }
    }

    func write(_ packets: [Data]) {
        flow.writePackets(
            packets,
            withProtocols: packets.map { NSNumber(value: $0.first.map { $0 >> 4 } == 6 ? AF_INET6 : AF_INET) }
        )
    }
}
