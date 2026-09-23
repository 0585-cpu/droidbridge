import DroidBridgeCore
import DroidBridgeShared
import Foundation

/// Effects the C engine raises. All bytes are already copied into Data; delegates run on the engine queue.
protocol EngineBridgeDelegate: AnyObject {
    func engineEmitPacket(_ data: Data)
    func engineOpenFlow(_ flow: UInt32, dstIP: [UInt8], port: UInt16)
    func engineSendFlow(_ flow: UInt32, _ data: Data) -> Int
    func engineCloseFlow(_ flow: UInt32, reason: Int)
    func engineSendDNS(_ flow: UInt32, _ query: Data)
    func engineOpenUDP(_ flow: UInt32, dstIP: [UInt8], port: UInt16)
    func engineSendUDP(_ flow: UInt32, _ data: Data)
    func engineCloseUDP(_ flow: UInt32)
    func engineSendICMP(_ request: UInt32, family: UInt8, dstIP: Data, ttl: UInt8, payload: Data)
}

/// Thread-safe wrapper around the C data-plane engine. Every C call and callback runs on one serial
/// queue, so the engine stays single-threaded as its contract requires.
final class EngineBridge: @unchecked Sendable {
    let queue = DispatchQueue(label: "io.droidbridge.packet-engine")
    weak var delegate: EngineBridgeDelegate?
    private var engine: OpaquePointer?
    private let pollTimer: EnginePollTimer

    init?(maximumFlows: UInt16 = 128, delegate: EngineBridgeDelegate) {
        pollTimer = EnginePollTimer(queue: queue)
        self.delegate = delegate
        var config = db_engine_config_t()
        config.maximum_flows = maximumFlows
        config.mtu = 1280
        config.idle_timeout_ms = 5 * 60 * 1000
        config.context = Unmanaged.passUnretained(self).toOpaque()
        config.emit_packet = db_bridge_emit
        config.open_flow = db_bridge_open
        config.open_flow_ip = db_bridge_open_ip
        config.open_udp = db_bridge_open_udp
        config.send_udp = db_bridge_send_udp
        config.close_udp = db_bridge_close_udp
        config.send_icmp = db_bridge_icmp
        config.send_flow = db_bridge_send
        config.close_flow = db_bridge_close
        config.send_dns = db_bridge_dns
        config.random_u32 = db_bridge_rand
        config.now_ms = db_bridge_now
        guard let created = db_engine_create(&config) else { return nil }
        engine = created
        pollTimer.start { [weak self] in
            guard let self, let engine = self.engine else { return }
            db_engine_poll(engine)
        }
    }

    deinit {
        pollTimer.stop()
        if let engine { db_engine_destroy(engine) }
    }

    /// Feed one IPv4 packet read from the tunnel. Bytes are copied into lwIP synchronously on the queue.
    func ingest(_ packet: Data) {
        queue.async { [self] in
            packet.withUnsafeBytes { raw in
                _ = db_engine_input_packet(engine, raw.bindMemory(to: UInt8.self).baseAddress, packet.count)
            }
        }
    }

    func stop() {
        pollTimer.stop()
        queue.sync {
            delegate = nil
            if let engine { db_engine_destroy(engine) }
            engine = nil
        }
    }

    func poll() { queue.async { [self] in db_engine_poll(engine) } }

    func relayOpened(_ flow: UInt32) { queue.async { [self] in _ = db_engine_on_relay_opened(engine, flow) } }
    func relayOpenFailed(_ flow: UInt32) { queue.async { [self] in _ = db_engine_on_relay_open_failed(engine, flow) } }
    func relayWritable(_ flow: UInt32) { queue.async { [self] in _ = db_engine_on_relay_writable(engine, flow) } }
    func relayClosed(_ flow: UInt32, isError: Bool) { queue.async { [self] in _ = db_engine_on_relay_closed(engine, flow, isError ? 1 : 0) } }

    func relayData(_ flow: UInt32, _ data: Data) {
        queue.async { [self] in
            data.withUnsafeBytes { raw in
                _ = db_engine_on_relay_data(engine, flow, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
        }
    }

    func dnsResponse(_ query: UInt32, _ response: Data) {
        queue.async { [self] in
            response.withUnsafeBytes { raw in
                _ = db_engine_on_dns_response(engine, query, raw.bindMemory(to: UInt8.self).baseAddress, response.count)
            }
        }
    }

    func setCapabilities(_ caps: RelayCapabilities) {
        queue.async { [self] in
            caps.nat64Prefix.withUnsafeBytes { raw in
                _ = db_engine_set_nat64_prefix(engine, raw.bindMemory(to: UInt8.self).baseAddress, caps.nat64PrefixLength)
            }
            db_engine_set_capabilities(engine, caps.flags)
        }
    }
    func blockCapabilities() { queue.async { [self] in db_engine_set_capabilities(engine, 0) } }
    /// Backpressure the framed reader until C consumes this datagram: at most one delivery per flow.
    func udpData(_ flow: UInt32, _ data: Data) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                data.withUnsafeBytes { raw in
                    _ = db_engine_on_udp_data(engine, flow, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
                }
                continuation.resume()
            }
        }
    }
    func udpClosed(_ flow: UInt32) { queue.async { [self] in _ = db_engine_on_udp_closed(engine, flow) } }
    func icmpResponse(_ request: UInt32, _ data: Data) {
        queue.async { [self] in data.withUnsafeBytes { raw in
            _ = db_engine_on_icmp_response(engine, request, raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        } }
    }
    func icmpFailed(_ request: UInt32) { queue.async { [self] in _ = db_engine_on_icmp_failed(engine, request) } }
    var activeUDP: Int { queue.sync { db_engine_udp_flow_count(engine) } }
    var udpDrops: UInt64 { queue.sync { db_engine_udp_drop_count(engine) } }
    var activeFlows: Int { queue.sync { db_engine_active_flow_count(engine) } }
}

extension EngineBridge: PacketIngesting {}
