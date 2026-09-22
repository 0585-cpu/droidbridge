import Darwin
import DroidBridgeShared
import Foundation

enum UtunError: LocalizedError {
    case operation(String, Int32)
    case command(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .operation(operation, code):
            return "\(operation) failed: \(String(cString: strerror(code))) (errno \(code))"
        case let .command(command, status):
            return "\(command) exited with status \(status)"
        }
    }
}

/// Owns one macOS utun control socket and exposes raw IPv4 packets.
final class UtunDevice: @unchecked Sendable {
    let interfaceName: String

    private let descriptorLock = NSLock()
    private var descriptor: Int32?
    private static let utunControlName = "com.apple.net.utun_control"
    private static let utunInterfaceNameOption: Int32 = 2
    private static let controlInfoRequest = UInt(0xC000_0000)
        | (UInt(MemoryLayout<ctl_info>.size) << 16)
        | (UInt(Character("N").asciiValue!) << 8)
        | 3

    init() throws {
        let socketDescriptor = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard socketDescriptor >= 0 else {
            throw UtunError.operation("socket(PF_SYSTEM)", errno)
        }

        do {
            var info = ctl_info()
            let nameCapacity = MemoryLayout.size(ofValue: info.ctl_name)
            let copiedLength = withUnsafeMutablePointer(to: &info.ctl_name) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { namePointer in
                    Self.utunControlName.withCString { source in
                        strlcpy(namePointer, source, nameCapacity)
                    }
                }
            }
            guard copiedLength < nameCapacity else {
                throw UtunError.operation("copy utun control name", ENAMETOOLONG)
            }
            guard ioctl(socketDescriptor, Self.controlInfoRequest, &info) >= 0 else {
                throw UtunError.operation("ioctl(CTLIOCGINFO)", errno)
            }

            var address = sockaddr_ctl(
                sc_len: UInt8(MemoryLayout<sockaddr_ctl>.size),
                sc_family: UInt8(AF_SYSTEM),
                ss_sysaddr: UInt16(AF_SYS_CONTROL),
                sc_id: info.ctl_id,
                sc_unit: 0,
                sc_reserved: (0, 0, 0, 0, 0)
            )
            let connectionResult = withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    connect(
                        socketDescriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_ctl>.size)
                    )
                }
            }
            guard connectionResult >= 0 else {
                throw UtunError.operation("connect(utun)", errno)
            }

            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var nameLength = socklen_t(name.count)
            let nameResult = getsockopt(
                socketDescriptor,
                SYSPROTO_CONTROL,
                Self.utunInterfaceNameOption,
                &name,
                &nameLength
            )
            guard nameResult >= 0 else {
                throw UtunError.operation("getsockopt(UTUN_OPT_IFNAME)", errno)
            }

            let interfaceBytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let resolvedInterfaceName = String(decoding: interfaceBytes, as: UTF8.self)
            guard !resolvedInterfaceName.isEmpty else {
                throw UtunError.operation("getsockopt(UTUN_OPT_IFNAME)", ENXIO)
            }

            descriptor = socketDescriptor
            interfaceName = resolvedInterfaceName
        } catch {
            Darwin.close(socketDescriptor)
            throw error
        }
    }

    deinit {
        close()
    }

    func read() -> Data? {
        guard let descriptor = descriptorLock.withLock({ descriptor }) else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65_535 + MemoryLayout<UInt32>.size)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return UtunFraming.decode(Data(buffer.prefix(count)))
    }

    func assignAddress(
        _ address: String = "198.18.0.2",
        peer: String = "198.18.0.1",
        mtu: Int = 1280
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = [
            interfaceName,
            "inet", address, peer,
            "netmask", "255.255.255.252",
            "mtu", String(mtu),
            "up",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UtunError.command("ifconfig \(interfaceName)", process.terminationStatus)
        }
    }

    @discardableResult
    func write(_ ipv4: Data) -> Bool {
        guard let descriptor = descriptorLock.withLock({ descriptor }) else { return false }
        let frame = UtunFraming.encode(ipv4)
        let written = frame.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, frame.count)
        }
        return written == frame.count
    }

    func close() {
        let descriptorToClose = descriptorLock.withLock { () -> Int32? in
            defer { descriptor = nil }
            return descriptor
        }
        if let descriptorToClose {
            Darwin.close(descriptorToClose)
        }
    }
}
