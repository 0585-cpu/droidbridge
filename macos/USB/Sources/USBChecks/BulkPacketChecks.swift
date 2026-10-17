import Foundation
import DroidBridgeUSB

func runBulkPacketChecks() throws {
    // Android completes a 16-KiB read only on capacity or a short USB packet.
    // Model that boundary: an exact full-packet tail must be followed by a ZLP.
    for (length, transfers) in [(511, [511]), (512, [512, 0]), (1024, [1024, 0]),
                                (16384, [16384]), (16400, [16384, 16])] {
        var actual: [Int] = []
        try AoaBulkWriter.write(Data(repeating: 7, count: length), maximumPacketSize: 512) { chunk in
            actual.append(chunk.count)
            return chunk.count
        }
        check(actual == transfers, "bulk packet termination at \(length) bytes")
    }
    do {
        try AoaBulkWriter.write(Data([1,2,3]), maximumPacketSize: 512) { _ in 2 }
        fatalError("partial USB write accepted")
    } catch {}
    print("AOA USB packet-boundary checks passed")
}
