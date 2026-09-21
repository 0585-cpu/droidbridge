import Foundation

/// Finds the adb binary in the documented order, without invoking a shell.
public struct AdbExecutableLocator: Sendable {
    private let environment: [String: String]
    private let fileExists: @Sendable (String) -> Bool

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) {
        self.environment = environment
        self.fileExists = fileExists
    }

    public func locate() throws -> URL {
        var candidates: [String] = []
        if let home = environment["ANDROID_HOME"] { candidates.append("\(home)/platform-tools/adb") }
        if let root = environment["ANDROID_SDK_ROOT"] { candidates.append("\(root)/platform-tools/adb") }
        candidates.append("/opt/homebrew/bin/adb")
        candidates.append("/usr/local/bin/adb")
        for dir in (environment["PATH"] ?? "").split(separator: ":") { candidates.append("\(dir)/adb") }
        for path in candidates where fileExists(path) { return URL(fileURLWithPath: path) }
        throw DroidBridgeError.adbNotFound
    }
}
