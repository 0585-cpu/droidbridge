import Foundation
import IOKit.pwr_mgt
import OSLog
import DroidBridgeShared
import DroidBridgeUSB

protocol AoaMultiplexing: AnyObject, Sendable {
    var isConnected: Bool { get }
    func start() throws
    func stop()
    func setEnabled(_ services: Set<AoaFrame.Service>)
}

extension AoaMultiplexer: AoaMultiplexing {
    func start() throws { _ = try start(relayPort: 27183, pairingPort: 27184) }
}

/// App-owned USB transport. Recovery never changes routes or pairing credentials.
actor AoaDeviceLink: RelayDeviceTransport {
    typealias SessionFactory = @Sendable (String, Bool, @escaping @Sendable (String) -> Void) -> any AoaMultiplexing
    private let libraryPath: String
    private let sessionFactory: SessionFactory
    private let retryDelays: [Duration]
    private let resetPort: @Sendable (String) throws -> Void
    private let logger = Logger(subsystem: "io.droidbridge", category: "USBRecovery")
    private var mux: (any AoaMultiplexing)?
    private var sessionID: UUID?
    private var selected: String?
    private var services: Set<AoaFrame.Service> = []
    private var opening: Task<Void, Error>?
    private var recovery: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var established = false
    private var recoveryEnabled = false
    private var asleep = false
    private var recovered: @Sendable () async -> Void = {}

    init(libraryPath: String) {
        self.libraryPath = libraryPath
        // About 90 s, past the phone's 60 s no-progress and 70 s host-silence deadlines: it keeps
        // the old session until then (seen: Mac gave up after 7 s, the phone reopened at 60 s).
        retryDelays = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)] + Array(repeating: .seconds(15), count: 5)
        sessionFactory = { serial, automatic, disconnected in
            let location = String(serial.dropFirst(4))
            return AoaMultiplexer(transportFactory: {
                // Automatic retries only reopen an accessory already at the selected port.
                if automatic {
                    guard try LibusbAccessoryTransport.devices(libraryPath: libraryPath)
                        .contains(where: { $0.location == location && $0.isAccessory }) else {
                        throw AoaError.usb("selected USB accessory is unavailable")
                    }
                }
                return try ReliableUsbTransport(raw: LibusbAccessoryTransport(libraryPath: libraryPath, location: location))
            }, disconnected: disconnected)
        }
        resetPort = { serial in try LibusbAccessoryTransport.reset(libraryPath: libraryPath, location: String(serial.dropFirst(4))) }
    }

    init(sessionFactory: @escaping SessionFactory, retryDelays: [Duration],
         resetPort: @escaping @Sendable (String) throws -> Void = { _ in }) {
        libraryPath = ""; self.sessionFactory = sessionFactory; self.retryDelays = retryDelays; self.resetPort = resetPort
    }

    func setRecoveryHandler(_ handler: @escaping @Sendable () async -> Void) { recovered = handler }

    // Off the actor: a libusb enumeration that hangs on a wedged phone must not block Stop.
    nonisolated func devices() throws -> [AdbDevice] {
        try LibusbAccessoryTransport.devices(libraryPath: libraryPath).map {
            AdbDevice(serial: $0.id, state: .authorized, model: $0.name, transportId: $0.location)
        }
    }

    func prepareDevice(serial: String) throws {
        guard serial.hasPrefix("aoa:"), serial.count > 4 else {
            throw AoaError.usb("select and pair this phone using USB accessory mode")
        }
    }

    func activateApp(serial: String) async throws {}

    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws {
        try prepareDevice(serial: serial)
        guard hostPort == devicePort, hostPort == 27183 || hostPort == 27184 else {
            throw AoaError.protocolViolation("only relay and pairing services are allowed")
        }
        cancelRecovery()
        if selected != serial { retireSession(); services = [] }
        selected = serial
        let service: AoaFrame.Service = hostPort == 27183 ? .relay : .pairing
        services.insert(service)
        recoveryEnabled = services.contains(.relay)
        let expected = generation
        do {
            if mux?.isConnected != true { try await open(serial: serial, automatic: false, expected: expected) }
            guard generation == expected else { throw CancellationError() }
            mux?.setEnabled(services)
        } catch {
            if generation == expected {
                services.remove(service)
                recoveryEnabled = services.contains(.relay)
                if services.isEmpty { selected = nil; retireSession() }
            }
            throw error
        }
    }

    /// Called before explicit Stop, so an in-flight USB open cannot revive the connection.
    func suspendRecovery() async { cancelRecovery() }

    private func cancelRecovery() {
        generation &+= 1
        recoveryEnabled = false
        recovery?.cancel(); recovery = nil
        if opening != nil { retireSession() }
    }

    /// Closing the lid suspended USB under the open session, and tearing that broken session down
    /// after wake hung libusb for the whole process until relaunch. Close it while the phone answers.
    func prepareForSleep() {
        guard recoveryEnabled, services.contains(.relay), selected != nil else { return }
        asleep = true
        recovery?.cancel(); recovery = nil
        retireSession()
        logger.notice("USB session closed for system sleep")
    }

    func resumeAfterWake() {
        guard asleep else { return }
        asleep = false
        guard recoveryEnabled, services.contains(.relay), let serial = selected, recovery == nil else { return }
        let expected = generation
        recovery = Task { [weak self] in await self?.recover(serial: serial, expected: expected) }
    }

    func removeForward(serial: String, hostPort: UInt16) async throws {
        guard serial == selected else { return }
        services.remove(hostPort == 27183 ? .relay : .pairing)
        if hostPort == 27183 || services.isEmpty { cancelRecovery() }
        mux?.setEnabled(services)
        if services.isEmpty { selected = nil; retireSession() }
    }

    private func retireSession() {
        sessionID = nil; established = false
        opening?.cancel(); opening = nil
        let old = mux; mux = nil
        old?.stop()
    }

    private func open(serial: String, automatic: Bool, expected: UInt64) async throws {
        guard generation == expected, !Task.isCancelled else { throw CancellationError() }
        retireSession()
        let id = UUID()
        let candidate = sessionFactory(serial, automatic) { [weak self] reason in
            Task { await self?.disconnected(id: id, reason: reason) }
        }
        sessionID = id; mux = candidate
        candidate.setEnabled(services)
        let task = Task.detached { try candidate.start() }
        opening = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel(); candidate.stop()
            }
            guard generation == expected, sessionID == id, !Task.isCancelled,
                  candidate.isConnected else { throw CancellationError() }
            opening = nil; established = true
            candidate.setEnabled(services)
        } catch {
            if sessionID == id { retireSession() }
            else { candidate.stop() }
            throw error
        }
    }

    private func disconnected(id: UUID, reason: String) {
        guard sessionID == id else { return }
        logger.error("USB session ended: \(reason, privacy: .public)")
        guard established else { return } // The caller/retry loop owns opening failures.
        retireSession()
        guard recoveryEnabled, services.contains(.relay), let serial = selected, recovery == nil else { return }
        let expected = generation
        recovery = Task { [weak self] in await self?.recover(serial: serial, expected: expected) }
    }

    private func recover(serial: String, expected: UInt64) async {
        var reset = false
        for (index, delay) in retryDelays.enumerated() {
            do {
                try await Task.sleep(for: delay)
                guard generation == expected, recoveryEnabled, selected == serial,
                      services.contains(.relay) else { return }
                // Two failed reopens: the phone's USB controller may be stuck in suspend (seen after
                // a charging change at full charge), which only a re-enumeration clears.
                if index == 2 && !reset {
                    reset = true
                    logger.notice("USB reopen keeps failing; resetting the USB port")
                    let resetPort = resetPort
                    do { try await Task.detached { try resetPort(serial) }.value }
                    catch { logger.error("USB port reset failed: \(error.localizedDescription, privacy: .public)") }
                    guard generation == expected, recoveryEnabled else { return }
                }
                logger.notice("USB automatic reconnect attempt \(index + 1)")
                // After a reset the phone can return outside accessory mode; let open switch it back.
                try await open(serial: serial, automatic: !reset, expected: expected)
                guard generation == expected, recoveryEnabled else { return }
                logger.notice("USB session restored; requesting authenticated relay health check")
                recovery = nil
                await recovered()
                return
            } catch {
                if Task.isCancelled || generation != expected { return }
                logger.error("USB reconnect failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if generation == expected { recovery = nil }
        logger.error("USB automatic retries exhausted; protection remains active")
    }
}

/// IOKit holds system sleep until each registered client replies (up to 30 s), so the USB session
/// is closed before the USB stack suspends rather than after.
final class SystemSleepObserver: @unchecked Sendable {
    // iokit_common_msg(...) values; the C macros are not imported into Swift.
    private static let canSystemSleep: natural_t = 0xe000_0270
    private static let systemWillSleep: natural_t = 0xe000_0280
    private static let systemHasPoweredOn: natural_t = 0xe000_0300
    nonisolated(unsafe) private static var installed: SystemSleepObserver? // set once at launch
    private let link: AoaDeviceLink
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    static func install(link: AoaDeviceLink) { installed = SystemSleepObserver(link: link) }

    private init(link: AoaDeviceLink) {
        self.link = link
        root = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { refcon, _, message, argument in
            guard let refcon else { return }
            Unmanaged<SystemSleepObserver>.fromOpaque(refcon).takeUnretainedValue().handle(message, argument)
        }, &notifier)
        if let port { IONotificationPortSetDispatchQueue(port, .main) }
    }

    private func handle(_ message: natural_t, _ argument: UnsafeMutableRawPointer?) {
        let root = root, token = Int(bitPattern: argument), link = link
        switch message {
        case Self.canSystemSleep: IOAllowPowerChange(root, token)
        case Self.systemWillSleep: Task { await link.prepareForSleep(); IOAllowPowerChange(root, token) }
        case Self.systemHasPoweredOn: Task { await link.resumeAfterWake() }
        default: break
        }
    }
}
