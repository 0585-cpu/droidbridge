import DroidBridgeShared
import Foundation

private final class PacketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []

    func append(_ batch: [Data]) {
        lock.withLock { packets.append(contentsOf: batch) }
    }

    var count: Int { lock.withLock { packets.count } }
}

private final class FakePacketSource: PacketSource {
    var queued: [[Data]]
    private(set) var written: [Data] = []

    init(_ batches: [[Data]]) {
        queued = batches
    }

    func read(_ handler: @escaping @Sendable ([Data]) -> Void) {
        guard !queued.isEmpty else { return }
        handler(queued.removeFirst())
    }

    func write(_ packets: [Data]) {
        written.append(contentsOf: packets)
    }
}

func runPacketSourceChecks(_ r: CheckRunner) {
    let source = FakePacketSource([[Data([0x45, 0x00]), Data([0x45, 0x01])]])
    let received = PacketRecorder()
    source.read { received.append($0) }
    r.check(received.count == 2, "read delivers one packet batch")

    source.write([Data([0xAA])])
    r.check(source.written == [Data([0xAA])], "write forwards packets")
    r.finish("packet source")
}
