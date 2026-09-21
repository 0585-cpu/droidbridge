import Foundation

public struct RelayPreparation: Sendable {
    public let health: RelayHealth
}

/// Minimal ADB surface the preparer needs (lets tests stub it without a real device).
public protocol RelayAdb: Sendable {
    func packagePath(serial: String, package: String) async throws -> String?
    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws
    func removeForward(serial: String, hostPort: UInt16) async throws
    func startActivity(serial: String, component: String) async throws
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

    private let adb: any RelayAdb
    private let healthClient: any RelayHealthChecking

    public init(adb: any RelayAdb, healthClient: any RelayHealthChecking) {
        self.adb = adb
        self.healthClient = healthClient
    }

    public func prepare(device: AdbDevice, secret: Data) async throws -> RelayPreparation {
        guard device.state == .authorized else { throw DroidBridgeError.deviceUnauthorized(serial: device.serial) }
        guard try await adb.packagePath(serial: device.serial, package: Self.androidPackage) != nil else {
            throw DroidBridgeError.relayAppNotRunning
        }

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
            try? await adb.startActivity(serial: device.serial, component: Self.activity)
            try? await adb.removeForward(serial: device.serial, hostPort: Self.relayPort)
            try? await adb.removeForward(serial: device.serial, hostPort: Self.pairingPort)
            throw error
        }
    }
}
