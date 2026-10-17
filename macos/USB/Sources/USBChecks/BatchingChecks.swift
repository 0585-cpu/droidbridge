import Foundation
import Darwin
import DroidBridgeUSB

func runBatchingChecks() throws {
    runWindowPolicyChecks()
    let epoch=Data(repeating: 0,count:16)
    func ready() throws -> ReliableUsbState {
        var s=ReliableUsbState(epoch:nil,now:0)
        _=try s.receive(ReliableUsbRecord(kind:.hello,epoch:epoch),now:0)
        _=try s.next(now:0);return s
    }
    var state=try ready()
    _=try state.receive(ReliableUsbRecord(kind:.data,epoch:epoch,sequence:1,payload:Data([7])),now:1)
    let early=try state.next(now:1)
    check(early == nil,"isolated DATA must wait briefly for ACK coalescing")
    let ack=try state.next(now:1.002)
    check(ack?.ack == 1 && ack?.kind == .ack,"isolated DATA ACK has 2ms maximum delay")
    state=try ready()
    for seq in 1...7 { _=try state.receive(ReliableUsbRecord(kind:.data,epoch:epoch,sequence:UInt64(seq),payload:Data([7])),now:1) }
    let beforeBatch=try state.next(now:1)
    check(beforeBatch == nil,"subthreshold batch waits")
    _=try state.receive(ReliableUsbRecord(kind:.data,epoch:epoch,sequence:8,payload:Data([7])),now:1.001)
    let batch=try state.next(now:1.001)
    check(batch?.ack == 8,"eight DATA records flush cumulative ACK")
    for seq in [UInt64(1),3] {
        state=try ready()
        _=try state.receive(ReliableUsbRecord(kind:.data,epoch:epoch,sequence:1,payload:Data([7])),now:1)
        _=try state.receive(ReliableUsbRecord(kind:.data,epoch:epoch,sequence:seq,payload:Data([7])),now:1.001)
        let immediate=try state.next(now:1.001)
        check(immediate?.ack == 1,"duplicate or gap immediately reports accepted prefix")
    }
    try runAlignedRawWriteCheck()
    try runAlignedMuxCheck()
    print("USB batching checks passed")
}

private final class BatchingRawWire: AoaByteTransport, @unchecked Sendable {
    private let condition=NSCondition()
    private var incoming: [Data]=[]
    private var writes: [[Data]]=[]
    private var stopped=false
    private let trace=AoaWriteTrace()
    func readChunk() throws -> Data? {
        condition.lock();defer { condition.unlock() }
        while incoming.isEmpty && !stopped { condition.wait() }
        return stopped ? nil : incoming.removeFirst()
    }
    func write(_ data:Data) throws {
        var chunks:[Data]=[]
        try trace.write(data,maximumPacketSize:512) { chunks.append($0);return $0.count }
        condition.withLock { writes.append(chunks);condition.broadcast() }
    }
    func feed(_ data:Data) { condition.withLock { incoming.append(data);condition.broadcast() } }
    func close() { condition.withLock { stopped=true;condition.broadcast() } }
    func next() throws -> [Data] {
        condition.lock();defer { condition.unlock() }
        let deadline=Date().addingTimeInterval(2)
        while writes.isEmpty && !stopped {
            guard condition.wait(until:deadline) else { throw AoaError.usb("raw write test timed out") }
        }
        guard !writes.isEmpty else { throw AoaError.usb("raw write test closed") }
        return writes.removeFirst()
    }
}

func runAlignedRawWriteCheck() throws {
    let raw=BatchingRawWire()
    let transport=ReliableUsbTransport(raw:raw,epoch:nil)
    let readerDone=DispatchSemaphore(value:0)
    Thread.detachNewThread {
        defer { readerDone.signal() }
        do { while try transport.readChunk() != nil {} } catch {}
    }
    defer {
        transport.close()
        check(readerDone.wait(timeout:.now()+2) == .success,"raw test reader shuts down")
    }
    let epoch=Data(repeating:0,count:16)
    raw.feed(try ReliableUsbRecord(kind:.hello,epoch:epoch).encoded())
    var decoder=ReliableUsbDecoder()
    let helloWrites=try raw.next()
    check(helloWrites.count == 1,"HELLO_ACK is a single raw write")
    let hello=try decoder.append(helloWrites[0])
    check(hello.count == 1 && hello[0].kind == .helloAck,"raw fixture handshake")
    let payload=Data((0..<AoaFrame.sendPayload).map { UInt8(truncatingIfNeeded:$0*7) })
    let encoded=try AoaFrame(type:.data,streamID:1,payload:payload).encoded()
    try transport.write(encoded)
    let writes=try raw.next()
    check(writes.map(\.count) == [16384],"aligned AOA DATA plus reliable record makes one descriptor write")
    let records=try decoder.append(writes[0])
    check(records.count == 1 && records[0].kind == .data && records[0].payload == encoded,"raw write retains exact AOA frame")
    raw.feed(try ReliableUsbRecord(kind:.ack,epoch:epoch,ack:records[0].sequence).encoded())
    print("16288 payload bytes produced one 16384-byte raw write through reliable framing")
}

func runWindowPolicyChecks() {
    var window=AoaWindowUpdate()
    check(!window.consumed(1,now:1),"small WINDOW consumption coalesces")
    check(window.deadline == 1.005,"first consumption starts 5ms deadline")
    check(!window.consumed(200,now:1.001) && window.deadline == 1.005,"later consumption does not postpone deadline")
    check(!window.isDue(1.0049) && window.isDue(1.005),"sparse consumption flushes on deadline")
    window.sent(200)
    check(window.deadline == nil && !window.consumed(200,now:2),"sent/unchanged window has no timer")
    let base: UInt64=0x1_0000_0000
    window.sent(base)
    check(!window.consumed(base+32767,now:3),"subthreshold consumption waits")
    check(window.consumed(base+32768,now:3.001),"half window flushes before deadline without truncation")
    window.sent(base+32768)
    check(!window.consumed(base+32769,now:4) && window.deadline == 4.005,"new window gets fresh deadline")
}

func runAlignedMuxCheck() throws {
    let wire=TestUSBWire();let mux=AoaMultiplexer(transport:wire)
    Thread.detachNewThread {
        do { let reset=try wire.next();wire.feed(try AoaFrame(type:.resetOK,streamID:0,payload:reset.payload)) }
        catch { fatalError("reset: \(error)") }
    }
    let ports=try mux.start(relayPort:0,pairingPort:0);defer { mux.stop() }
    let client=try connectLocal(ports.relay);defer { Darwin.close(client) }
    let open=try wire.next();wire.feed(try AoaFrame(type:.openOK,streamID:open.streamID))
    let body=Data((0..<65536).map { UInt8(truncatingIfNeeded:$0*7) })
    try body.withUnsafeBytes { bytes in
        var sent=0
        while sent<bytes.count {
            let n=Darwin.send(client,bytes.baseAddress!.advanced(by:sent),bytes.count-sent,0)
            guard n>0 else { throw AoaError.usb("test socket send failed") };sent+=n
        }
    }
    var received=Data();var frames=0
    while received.count<body.count {
        let frame=try wire.next()
        check(frame.type == .data && frame.payload.count<=16288,"mux DATA fits one reliable/raw write")
        received.append(frame.payload);frames+=1
        wire.feed(try AoaFrame(type:.window,streamID:open.streamID,payload:AoaFrame.consumedBytes(UInt64(received.count))))
    }
    check(received == body,"aligned mux preserves exact byte stream")
    print("65536 socket bytes delivered in \(frames) bounded DATA frames")
}
