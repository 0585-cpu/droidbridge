import Foundation
import DroidBridgeShared

private final class SessionPacketSource: PacketSource {
    var readers: [@Sendable ([Data]) -> Void] = []
    var written: [Data] = []
    func read(_ handler: @escaping @Sendable ([Data]) -> Void) { readers.append(handler) }
    func write(_ packets: [Data]) { written.append(contentsOf: packets) }
}
private final class SessionIngester: PacketIngesting {
    var packets: [Data] = []
    weak var delegate: (any EngineBridgeDelegate)?
    init(_ delegate: any EngineBridgeDelegate) { self.delegate = delegate }
    func ingest(_ packet: Data) { packets.append(packet) }
}
func runControllerSessionChecks() {
    let source = SessionPacketSource()
    var engines: [SessionIngester] = []
    let controller = TunnelController(packetSource: source, secret: Data(count:32), engineFactory: { _, delegate in
        let engine = SessionIngester(delegate); engines.append(engine); return engine
    })
    precondition(controller.start() && !controller.start(), "only one running session")
    let oldDelegate = engines[0].delegate
    source.readers[0]([Data([1])])
    precondition(engines[0].packets == [Data([1])])
    controller.stop()
    precondition(controller.start(), "restart creates new session")
    let newReader = source.readers.count - 1
    source.readers[1]([Data([2])]) // completion of old pending read
    oldDelegate?.engineEmitPacket(Data([3])) // late callback from retained old engine
    precondition(engines[1].packets.isEmpty && source.written.isEmpty, "old callbacks cannot reach restarted session")
    source.readers[newReader]([Data([4])])
    engines[1].delegate?.engineEmitPacket(Data([5]))
    precondition(engines[1].packets == [Data([4])] && source.written == [Data([5])], "new session remains active")
    controller.stop(); controller.stop()
    print("controller session isolation: passed")
}

private final class StoppedEngineDelegate: EngineBridgeDelegate {
    func engineEmitPacket(_ data: Data) {}
    func engineOpenFlow(_ flow: UInt32, dstIP: [UInt8], port: UInt16) {}
    func engineSendFlow(_ flow: UInt32, _ data: Data) -> Int { data.count }
    func engineCloseFlow(_ flow: UInt32, reason: Int) {}
    func engineSendDNS(_ flow: UInt32, _ query: Data) {}
    func engineOpenUDP(_ flow: UInt32, dstIP: [UInt8], port: UInt16) {}
    func engineSendUDP(_ flow: UInt32, _ data: Data) {}
    func engineCloseUDP(_ flow: UInt32) {}
    func engineSendICMP(_ request: UInt32, family: UInt8, dstIP: Data, ttl: UInt8, payload: Data) {}
}
func runStoppedEngineCheck() {
    let delegate = StoppedEngineDelegate()
    let engine = EngineBridge(maximumFlows: 4, delegate: delegate)!
    let bytes: [UInt8] = [0x45,0,0,0x28,0,1,0,0,0x40,6,0xb2,0xb9,0xc6,0x12,0,2,1,1,1,1,0x9c,0x40,1,0xbb,0,0,0,1,0,0,0,0,0x50,2,0x10,0,0x39,0xd0,0,0]
    engine.ingest(Data(bytes))
    precondition(engine.activeFlows == 1, "SYN creates a live flow")
    engine.stop()
    guard engine.activeFlows == 0 else {
        FileHandle.standardError.write(Data("FAIL: stopped engine retains live C flow while wrapper is retained\n".utf8))
        exit(EXIT_FAILURE)
    }
    // Retained wrapper from late async work must no longer poll or mutate process-global lwIP state.
    let replacement = EngineBridge(maximumFlows: 4, delegate: delegate)!
    replacement.ingest(Data(bytes)); engine.poll(); engine.relayClosed(1, isError: true)
    precondition(replacement.activeFlows == 1, "late old-engine operations leave replacement intact")
    replacement.stop()
    print("stopped engine destruction: passed")
}
