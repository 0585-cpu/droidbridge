import Foundation
import DroidBridgeShared
import DroidBridgeUSB

/// App-owned USB transport. The privileged helper sees only authenticated loopback DBP streams.
actor AoaDeviceLink: RelayDeviceTransport {
    private let libraryPath: String
    private var mux: AoaMultiplexer?
    private var selected: String?
    private var services: Set<AoaFrame.Service> = []
    private var opening: Task<AoaMultiplexer, Error>?

    init(libraryPath: String) { self.libraryPath = libraryPath }

    func devices() throws -> [AdbDevice] {
        // AdbDevice remains the shared device-list value type for legacy checks; no ADB runs here.
        try LibusbAccessoryTransport.devices(libraryPath: libraryPath).map {
            AdbDevice(serial: $0.id, state: .authorized, model: $0.name, transportId: $0.location)
        }
    }

    func prepareDevice(serial: String) throws {
        guard serial.hasPrefix("aoa:"), serial.count > 4 else {
            throw AoaError.usb("select and pair this phone using USB accessory mode")
        }
    }

    func activateApp(serial: String) async throws {
        // Android's accessory attach intent opens the app with a user permission prompt.
    }

    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws {
        try prepareDevice(serial: serial)
        guard hostPort == devicePort, hostPort == 27183 || hostPort == 27184 else {
            throw AoaError.protocolViolation("only relay and pairing services are allowed")
        }
        if selected != serial || mux?.isConnected == false {
            mux?.stop(); mux = nil; services = []
        }
        if let opening, selected != serial {
            _ = opening
            throw AoaError.usb("another phone is connecting")
        }
        selected = serial
        if mux == nil {
            if opening == nil {
                let path = libraryPath
                let location = String(serial.dropFirst(4))
                opening = Task.detached {
                    let next = AoaMultiplexer(transportFactory: {
                        try LibusbAccessoryTransport(libraryPath: path, location: location)
                    })
                    _ = try next.start()
                    return next
                }
            }
            do { mux = try await opening!.value; opening = nil }
            catch { opening = nil; selected = nil; throw error }
        }
        services.insert(hostPort == 27183 ? .relay : .pairing)
        mux?.setEnabled(services)
    }

    func removeForward(serial: String, hostPort: UInt16) async throws {
        guard serial == selected else { return }
        services.remove(hostPort == 27183 ? .relay : .pairing)
        mux?.setEnabled(services)
        if services.isEmpty { mux?.stop(); mux = nil; selected = nil }
    }
}
