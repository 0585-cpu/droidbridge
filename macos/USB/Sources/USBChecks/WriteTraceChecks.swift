import Foundation
import DroidBridgeUSB

func runWriteTraceChecks() throws {
    let trace = AoaWriteTrace()
    let frame = try AoaFrame(type: .data, streamID: 1, payload: Data(repeating: 0x5a, count: 16_384)).encoded()
    var transfers: [Data] = []
    try trace.write(frame, maximumPacketSize: 512) { transfers.append($0); return $0.count }
    let snapshot = trace.snapshot()
    check(transfers.map(\.count) == [16_384, 16], "trace preserves maximum DATA transfer boundaries")
    check(snapshot.recent.count == 2, "trace retains both maximum DATA transfers")
    let first = snapshot.recent[0], tail = snapshot.recent[1]
    check(first.frame == 1 && first.frameType == 3 && first.frameLength == 16_400 && first.chunkOffset == 0,
          "trace identifies encoded frame and first chunk")
    check(first.sha256 == "b5260aef3eea57340537b68414adcfccb58ce8d55bb0f84270a0bdb01b0d1a8c",
          "whole transfer SHA256 matches independent vector")
    check(first.prefix16Sha256 == "eaf02218215555c609df7966f90b03fcd674fca93acf0777098f77e42b75e8d8",
          "header prefix SHA256 matches independent vector")
    check(tail.sha256 == "1c712ecc21e27e374111d5a1beeaf75a4e343b3814c1847cba14013420809873"
          && tail.prefix16Sha256 == tail.sha256 && tail.chunkOffset == 16_384 && tail.endOffset == 16_400,
          "tail has independent fingerprint and byte position")
    check(snapshot.maximumPacketSize == 512 && first.suffixes.count == 31 && tail.suffixes.isEmpty,
          "trace records endpoint packet size and bounded aligned suffixes")
    let missingPrefix = AoaWriteTrace()
    let sent1212 = try AoaFrame(type: .data, streamID: 1, payload: Data(repeating: 0x5a, count: 1196)).encoded()
    try missingPrefix.write(sent1212, maximumPacketSize: 512) { $0.count }
    let sent = missingPrefix.snapshot().recent[0]
    let received700Hash = "ddc821426ba897f5ea567317276fdd1ceef54c697603e9a5645201d9eda2993b"
    check(sent.sha256 != received700Hash && sent.suffixes.contains {
        $0.removedPrefix == 512 && $0.length == 700 && $0.sha256 == received700Hash
    }, "a missing USB packet prefix has an exact independently computed suffix match")
    let fullSpeed = AoaWriteTrace()
    try fullSpeed.write(frame, maximumPacketSize: 64) { $0.count }
    check(fullSpeed.snapshot().recent[0].suffixes.count == 32
          && fullSpeed.snapshot().recent[0].suffixes.last?.removedPrefix == 2048,
          "small packet size cannot exceed 32 stored suffix hashes")

    let aligned = try AoaFrame(type: .data, streamID: 1, payload: Data(repeating: 0x5a, count: 496)).encoded()
    try trace.write(aligned, maximumPacketSize: 512) { $0.count }
    let zlp = trace.snapshot().recent.last!
    check(zlp.requested == 0 && zlp.returned == 0 && zlp.chunkOffset == 512 && zlp.endOffset == 16_912,
          "trace preserves and records short aligned transfer ZLP")
    check(zlp.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "ZLP hashes empty input")

    let failed = AoaWriteTrace()
    var attempts = 0
    do {
        try failed.write(frame, maximumPacketSize: 512) { _ in attempts += 1; return -7 }
        fatalError("FAIL: trace accepted failed write")
    } catch {
        check(error.localizedDescription == "USB connection: could not write USB data (USB error -7)",
              "trace preserves USB error wording")
    }
    check(attempts == 1 && failed.snapshot().recent.last?.returned == -7 && failed.snapshot().bytesReported == 0,
          "failed transfer recorded without replay or invented partial count")
    let short = AoaWriteTrace()
    rejects("short traced write") { try short.write(frame, maximumPacketSize: 512) { _ in 7 } }
    check(short.snapshot().bytesReported == 7 && short.snapshot().recent.count == 1,
          "positive short write accounted once before failure")

    let bounded = AoaWriteTrace()
    let reset = try AoaFrame(type: .reset, streamID: 0, payload: Data(repeating: 0x12, count: 16)).encoded()
    try bounded.write(reset, maximumPacketSize: 512) { $0.count }
    let ping = try AoaFrame(type: .ping, streamID: 0).encoded()
    for _ in 0..<8193 { try bounded.write(ping, maximumPacketSize: 512) { $0.count } }
    let ring = bounded.snapshot()
    check(ring.recent.count == 8192 && ring.recent.first?.ordinal == 3 && ring.recent.last?.ordinal == 8194,
          "trace ring preserves only latest 8192 records")
    check(ring.first?.ordinal == 1 && ring.first?.frameType == 7 && ring.first?.frameLength == 32,
          "first RESET metadata and hash survive ring eviction")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridgeWriteTraceChecks-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let unrelated = directory.appendingPathComponent("unrelated.json")
    try Data("keep".utf8).write(to: unrelated)
    let unrelatedDirectory = directory.appendingPathComponent("usb-out-trace-\(UUID()).json")
    try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: false)
    var saved: URL?
    for _ in 0..<5 { saved = try trace.save(in: directory) }
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    check(files.count == 6 && FileManager.default.fileExists(atPath: unrelated.path)
          && FileManager.default.fileExists(atPath: unrelatedDirectory.path), "trace retains at most four owned files and preserves unrelated files/directories")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AoaWriteTrace.Snapshot.self, from: Data(contentsOf: saved!))
    check(decoded.calls == 4 && decoded.recent[0].sha256 == first.sha256, "saved trace remains machine readable")
    let incidentDirectory = directory.appendingPathComponent("incident")
    let incident = AoaWriteTrace()
    try incident.write(frame, maximumPacketSize: 512) { $0.count }
    rejects("incident USB failure") { try incident.write(frame, maximumPacketSize: 512) { _ in -1 } }
    let original = try incident.save(in: incidentDirectory)!
    for _ in 0..<8 {
        let retry = AoaWriteTrace()
        rejects("immediate retry failure") { try retry.write(reset, maximumPacketSize: 512) { _ in -1 } }
        _ = try retry.save(in: incidentDirectory)
    }
    check(FileManager.default.fileExists(atPath: original.path),
          "zero-byte recovery failures must not evict the original established-session failure")
    if let evidence = ProcessInfo.processInfo.environment["DROIDBRIDGE_USB_TRACE_EVIDENCE"] {
        if let saved = try missingPrefix.save(in: URL(fileURLWithPath: evidence)) {
            print("Synthetic USB trace evidence: \(saved.path)")
        }
    }
    print("AOA payload-free write trace checks passed")
}
