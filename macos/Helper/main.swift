import Darwin
import Foundation

private let utunControlName = "com.apple.net.utun_control"
private let controlInfoRequest = UInt(0xC000_0000)
    | (UInt(MemoryLayout<ctl_info>.size) << 16)
    | (UInt(Character("N").asciiValue!) << 8)
    | 3

private func openUtun() -> Int32 {
    let descriptor = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
    guard descriptor >= 0 else {
        NSLog("socket(PF_SYSTEM) failed: %s", strerror(errno))
        return -1
    }

    var info = ctl_info()
    let controlNameCapacity = MemoryLayout.size(ofValue: info.ctl_name)
    let controlNameWasCopied = withUnsafeMutablePointer(to: &info.ctl_name) { tuplePointer in
        tuplePointer.withMemoryRebound(
            to: CChar.self,
            capacity: controlNameCapacity
        ) { namePointer in
            utunControlName.withCString { source in
                strlcpy(namePointer, source, controlNameCapacity)
            }
        }
    }
    guard controlNameWasCopied < controlNameCapacity else {
        NSLog("utun control name is unexpectedly long")
        close(descriptor)
        return -1
    }

    guard ioctl(descriptor, controlInfoRequest, &info) >= 0 else {
        NSLog("CTLIOCGINFO failed: %s", strerror(errno))
        close(descriptor)
        return -1
    }

    var address = sockaddr_ctl(
        sc_len: UInt8(MemoryLayout<sockaddr_ctl>.size),
        sc_family: UInt8(AF_SYSTEM),
        ss_sysaddr: UInt16(AF_SYS_CONTROL),
        sc_id: info.ctl_id,
        sc_unit: 0,
        sc_reserved: (0, 0, 0, 0, 0)
    )
    let connectResult = withUnsafePointer(to: &address) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_ctl>.size))
        }
    }
    guard connectResult >= 0 else {
        NSLog("utun connect failed: %s", strerror(errno))
        close(descriptor)
        return -1
    }
    return descriptor
}

NSLog("DroidBridgeHelper spike starting as uid=%u", getuid())
let utunDescriptor = openUtun()
NSLog("utun open fd=%d (a nonnegative descriptor means an interface was created)", utunDescriptor)

guard utunDescriptor >= 0 else {
    exit(EXIT_FAILURE)
}

RunLoop.main.run()
