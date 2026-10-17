import DroidBridgeShared
import Foundation
import Darwin

private func waitForEOFPeer(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()+2) == .success
}

/// Real TCP/NWConnection regression: the last callback can carry data AND EOF.
/// A subsequent NW receive would report POSIX 96, turning clean completion into RST.
func runNetworkEOFChecks(_ r: CheckRunner) async {
    for exact in [false, true] {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            r.check(false, "EOF test listener binds"); continue
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let expected = exact ? 64 : 1_048_576
        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            defer { finished.signal() }
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer { Darwin.close(fd) }
            var noSignal: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            let bytes = [UInt8](repeating: 42, count: expected)
            bytes.withUnsafeBytes { buffer in
                var pos = 0
                while pos < buffer.count {
                    let n = Darwin.send(fd, buffer.baseAddress!.advanced(by: pos), buffer.count-pos, 0)
                    if n <= 0 { return }; pos += n
                }
            }
            _ = Darwin.shutdown(fd, SHUT_WR)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            _ = Darwin.recv(fd, &byte, 1, 0) // caller's cancel ends the peer lifetime
        }
        let transport = NWConnectionTransport(port: UInt16(bigEndian: address.sin_port))
        do {
            try await transport.start()
            var output = Data()
            if exact { output = try await transport.receiveExactly(expected) }
            while true {
                let bytes = try await transport.receive(maxLength: 65_536)
                if bytes.isEmpty { break }
                output.append(bytes)
                try await Task.sleep(for: .milliseconds(20))
            }
            r.check(output == Data(repeating: 42, count: expected), "real TCP final bytes precede clean EOF (exact=\(exact))")
            let repeatedEOF = try await transport.receive(maxLength: 1)
            r.check(repeatedEOF.isEmpty, "EOF is remembered without another NW receive")
        } catch { r.check(false, "real TCP final-data/EOF failed (exact=\(exact)): \(error)") }
        await transport.cancel()
        let stopped = await Task.detached { waitForEOFPeer(finished) }.value
        r.check(stopped, "EOF test peer stops")
    }
    r.finish("real network EOF")
}

/// The peer deliberately waits for our TCP FIN before replying on the same socket.
func runNetworkHalfCloseChecks(_ r: CheckRunner) async {
    let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(listener) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else { r.check(false, "half-close listener binds"); return }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { done.signal() }
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var noSignal: Int32 = 1, timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var request = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n < 0 { return }
            if n == 0 { break }
            request.append(contentsOf: buffer.prefix(n))
        }
        request.append(contentsOf: [0x46, 0x49, 0x4e])
        request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset, 0)
                if n <= 0 { return }; offset += n
            }
        }
        _ = Darwin.shutdown(fd, SHUT_WR)
    }
    let transport = NWConnectionTransport(port: UInt16(bigEndian: address.sin_port))
    let request = Data(repeating: 0x5a, count: 300_000)
    do {
        try await transport.start()
        try await transport.send(request)
        try await transport.finishSending()
        var response = Data()
        while true {
            let bytes = try await transport.receive(maxLength: 65536)
            if bytes.isEmpty { break }
            response.append(bytes)
        }
        r.check(response == request + Data([0x46,0x49,0x4e]), "TCP FIN preserves all request bytes and delayed reverse response")
    } catch { r.check(false, "native TCP half-close failed: \(error)") }
    await transport.cancel()
    let stopped = await Task.detached { waitForEOFPeer(done) }.value
    r.check(stopped, "half-close peer stops")
    r.finish("real network half-close")
}
