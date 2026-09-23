import Foundation

public struct RelayPreparation: Sendable {
    public let health: RelayHealth
}

/// A transport exposes only the two local services used by DBP and pairing.
public protocol RelayForwarding: Sendable {
    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws
    func removeForward(serial: String, hostPort: UInt16) async throws
}

public protocol RelayDeviceTransport: RelayForwarding {
    func prepareDevice(serial: String) async throws
    func activateApp(serial: String) async throws
}

/// Legacy development transport; the shipping host uses AOA.
public protocol RelayAdb: RelayDeviceTransport {
    func packagePath(serial: String, package: String) async throws -> String?
    func startActivity(serial: String, component: String) async throws
}

public extension RelayAdb {
    func prepareDevice(serial: String) async throws {
        guard try await packagePath(serial: serial, package: RelayPreparer.androidPackage) != nil else {
            throw DroidBridgeError.relayAppNotRunning
        }
    }
    func activateApp(serial: String) async throws {
        try await startActivity(serial: serial, component: RelayPreparer.activity)
    }
}

extension AdbClient: RelayAdb {
    public func packagePath(serial: String, package: String) async throws -> String? {
        try await packagePath(serial: serial, package: package, timeout: nil)
    }
    public func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws {
        try await forward(serial: serial, hostPort: hostPort, devicePort: devicePort, timeout: nil)
    }
    public func removeForward(serial: String, hostPort: UInt16) async throws {
        try await removeForward(serial: serial, hostPort: hostPort, timeout: nil)
    }
    public func startActivity(serial: String, component: String) async throws {
        try await startActivity(serial: serial, component: component, timeout: nil)
    }
}

/// Health client abstraction so preparation is testable without a socket.
public protocol RelayHealthChecking: Sendable {
    func health(secret: Data) async throws -> RelayHealth
}

public struct RelayPreparer: Sendable {
    public static let pairingPort: UInt16 = 27184
    public static let relayPort: UInt16 = 27183
    public static let androidPackage = "io.droidbridge.android"
    public static let activity = "io.droidbridge.android/io.droidbridge.MainActivity"

    private let adb: any RelayDeviceTransport
    private let healthClient: any RelayHealthChecking

    public init(adb: any RelayDeviceTransport, healthClient: any RelayHealthChecking) {
        self.adb = adb
        self.healthClient = healthClient
    }

    public func prepare(device: AdbDevice, secret: Data) async throws -> RelayPreparation {
        guard device.state == .authorized else { throw DroidBridgeError.deviceUnauthorized(serial: device.serial) }
        try await adb.prepareDevice(serial: device.serial)

        try await adb.forward(serial: device.serial, hostPort: Self.pairingPort, devicePort: Self.pairingPort)
        do {
            try await adb.forward(serial: device.serial, hostPort: Self.relayPort, devicePort: Self.relayPort)
        } catch {
            // roll back only the forward we already created
            try? await adb.removeForward(serial: device.serial, hostPort: Self.pairingPort)
            throw error
        }

        do {
            let health = try await healthClient.health(secret: secret)
            return RelayPreparation(health: health)
        } catch {
            // relay not answering yet: nudge the app to the foreground, then surface the error
            try? await adb.activateApp(serial: device.serial)
            try? await adb.removeForward(serial: device.serial, hostPort: Self.relayPort)
            try? await adb.removeForward(serial: device.serial, hostPort: Self.pairingPort)
            throw error
        }
    }
}
