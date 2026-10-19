import Foundation
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
    }

    init(sessionFactory: @escaping SessionFactory, retryDelays: [Duration]) {
        libraryPath = ""; self.sessionFactory = sessionFactory; self.retryDelays = retryDelays
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
        for (index, delay) in retryDelays.enumerated() {
            do {
                try await Task.sleep(for: delay)
                guard generation == expected, recoveryEnabled, selected == serial,
                      services.contains(.relay) else { return }
                logger.notice("USB automatic reconnect attempt \(index + 1)")
                try await open(serial: serial, automatic: true, expected: expected)
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
