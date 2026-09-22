import Foundation

/// Prefers the shared App Group only when the current signed process can complete an atomic write
/// there. Development provisioning profiles may return a container URL without granting write
/// access; in that case the host app uses its private Application Support directory instead.
public enum RuntimeConfigurationDirectoryResolver {
    public static func resolve(
        fileManager: FileManager = .default,
        appGroupContainer: URL?,
        fallbackDirectory: URL
    ) -> URL {
        guard let appGroupContainer else { return fallbackDirectory }

        let directoryAlreadyExisted = fileManager.fileExists(atPath: appGroupContainer.path)
        let probe = appGroupContainer
            .appendingPathComponent(".droidbridge-write-probe-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: appGroupContainer, withIntermediateDirectories: true)
            try Data().write(to: probe, options: .atomic)
            try fileManager.removeItem(at: probe)
            return appGroupContainer
        } catch {
            try? fileManager.removeItem(at: probe)
            if !directoryAlreadyExisted {
                try? fileManager.removeItem(at: appGroupContainer)
            }
            return fallbackDirectory
        }
    }
}
