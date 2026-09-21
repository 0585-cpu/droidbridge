import Foundation

public protocol RuntimeConfigurationStore: Sendable {
    func write(_ configuration: TunnelRuntimeConfiguration) throws
    func read() throws -> TunnelRuntimeConfiguration?
    func delete() throws
}

/// Writes the non-secret runtime config to an App Group file atomically, mode 0600, via a sibling temp
/// file + fsync + FileManager.replaceItemAt. Never stores secret material.
public struct FileRuntimeConfigurationStore: RuntimeConfigurationStore {
    public let fileURL: URL
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("tunnel-runtime.json")
    }

    public func write(_ configuration: TunnelRuntimeConfiguration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.droidBridge.encode(configuration)
        let tempURL = directory.appendingPathComponent(".tunnel-runtime.\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func read() throws -> TunnelRuntimeConfiguration? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(TunnelRuntimeConfiguration.self, from: data)
        } catch {
            throw DroidBridgeError.invalidConfiguration("corrupted runtime configuration")
        }
    }

    public func delete() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
