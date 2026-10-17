import DroidBridgeCore
import Foundation

// C-ABI trampolines. Each retrieves the EngineBridge from the engine's context pointer and copies any
// inbound bytes into a Swift Data before touching the delegate. Swift never retains C pointers.

func db_bridge_emit(_ ctx: UnsafeMutableRawPointer?, _ packet: UnsafePointer<UInt8>?, _ length: Int) {
    guard let ctx, let packet else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineEmitPacket(Data(bytes: packet, count: length))
}

func db_bridge_open(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ dst: UnsafePointer<UInt8>?, _ port: UInt16) {
    guard let ctx, let dst else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    let ip = [dst[0], dst[1], dst[2], dst[3]]
    bridge.delegate?.engineOpenFlow(flow, dstIP: ip, port: port)
}

func db_bridge_send(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ data: UnsafePointer<UInt8>?, _ length: Int) -> Int {
    guard let ctx, let data else { return Int(DB_SEND_ERROR) }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    return bridge.delegate?.engineSendFlow(flow, Data(bytes: data, count: length)) ?? Int(DB_SEND_ERROR)
}

func db_bridge_close(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ reason: db_close_reason_t) {
    guard let ctx else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineCloseFlow(flow, reason: Int(reason.rawValue))
}

func db_bridge_dns(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ query: UnsafePointer<UInt8>?, _ length: Int) {
    guard let ctx, let query else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineSendDNS(flow, Data(bytes: query, count: length))
}

func db_bridge_rand(_ ctx: UnsafeMutableRawPointer?) -> UInt32 { arc4random() }

func db_bridge_now(_ ctx: UnsafeMutableRawPointer?) -> UInt32 {
    UInt32(truncatingIfNeeded: UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000))
}

func db_bridge_open_ip(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ family: UInt8, _ dst: UnsafePointer<UInt8>?, _ port: UInt16) {
    guard let ctx, let dst, family == 4 || family == 6 else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineOpenFlow(flow, dstIP: Array(UnsafeBufferPointer(start: dst, count: family == 4 ? 4 : 16)), port: port)
}
func db_bridge_open_udp(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ family: UInt8, _ dst: UnsafePointer<UInt8>?, _ port: UInt16) {
    guard let ctx, let dst, family == 4 || family == 6 else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineOpenUDP(flow, dstIP: Array(UnsafeBufferPointer(start: dst, count: family == 4 ? 4 : 16)), port: port, sourcePort: 0, sourceIP: [])
}
func db_bridge_open_udp_endpoint(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ family: UInt8, _ dst: UnsafePointer<UInt8>?, _ port: UInt16, _ sourcePort: UInt16, _ src: UnsafePointer<UInt8>?) {
    guard let ctx, let dst, let src, family == 4 || family == 6 else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineOpenUDP(flow, dstIP: Array(UnsafeBufferPointer(start: dst, count: family == 4 ? 4 : 16)), port: port, sourcePort: sourcePort, sourceIP: Array(UnsafeBufferPointer(start: src, count: family == 4 ? 4 : 16)))
}
func db_bridge_send_udp(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ data: UnsafePointer<UInt8>?, _ length: Int) {
    guard let ctx, length == 0 || data != nil else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineSendUDP(flow, length == 0 ? Data() : Data(bytes: data!, count: length))
}
func db_bridge_close_udp(_ ctx: UnsafeMutableRawPointer?, _ flow: UInt32, _ reason: db_close_reason_t) {
    guard let ctx else { return }
    Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue().delegate?.engineCloseUDP(flow)
}
func db_bridge_icmp(_ ctx: UnsafeMutableRawPointer?, _ request: UInt32, _ family: UInt8, _ dst: UnsafePointer<UInt8>?, _ ttl: UInt8, _ data: UnsafePointer<UInt8>?, _ length: Int) {
    guard let ctx, let dst, family == 4 || family == 6, length == 0 || data != nil else { return }
    let bridge = Unmanaged<EngineBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.delegate?.engineSendICMP(request, family: family, dstIP: Data(bytes: dst, count: family == 4 ? 4 : 16), ttl: ttl, payload: length == 0 ? Data() : Data(bytes: data!, count: length))
}
