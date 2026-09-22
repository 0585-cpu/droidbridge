import DroidBridgeShared
import CryptoKit
import Foundation
import Security

enum ManualHelperInstallerError: LocalizedError {
    case missingEmbeddedFile(String)
    case invalidLaunchDaemonPlist
    case invalidHelperSignature(OSStatus)
    case authorizationFailed(operation: String, message: String)
    case removalIncomplete

    var errorDescription: String? {
        switch self {
        case let .missingEmbeddedFile(path):
            return "the signed app is missing \(path)"
        case .invalidLaunchDaemonPlist:
            return "the embedded launch daemon plist is invalid"
        case let .invalidHelperSignature(status):
            return "the embedded helper failed code-signature validation (\(status))"
        case let .authorizationFailed(operation, message):
            return "administrator-authorized helper \(operation) failed: \(message)"
        case .removalIncomplete:
            return "the privileged helper files remain after the removal command"
        }
    }
}

/// Installs the free-certificate helper after an explicit macOS administrator prompt.
struct ManualHelperInstaller: Sendable {
    private static let relativeDirectory = "Contents/Library/LaunchDaemons"
    private static let helperName = "DroidBridgeHelper"
    private static let plistName = "io.droidbridge.helper.plist"
    static let machServicePlistKeyPath = #"MachServices.io\.droidbridge\.helper"#

    private let bundleURL: URL
    private let runner: any ProcessRunning
    private let helperRequirement: String

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        runner: any ProcessRunning = FoundationProcessRunner(),
        teamID: String? = RuntimeSigningIdentity.teamID()
    ) {
        self.bundleURL = bundleURL
        self.runner = runner
        helperRequirement = HelperCodeRequirement.string(
            teamID: teamID ?? "UNSIGNEDBUILD",
            bundleID: "io.droidbridge.helper"
        )
    }

    func install() async throws {
        let embeddedDirectory = bundleURL.appendingPathComponent(Self.relativeDirectory)
        let helperURL = embeddedDirectory.appendingPathComponent(Self.helperName)
        let plistURL = embeddedDirectory.appendingPathComponent(Self.plistName)
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw ManualHelperInstallerError.missingEmbeddedFile(helperURL.path)
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw ManualHelperInstallerError.missingEmbeddedFile(plistURL.path)
        }

        try validateHelper(at: helperURL)
        let plistDigest = try validatePlist(at: plistURL)

        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: [
                "-e", Self.appleScript,
                "--", helperURL.path, plistURL.path, helperRequirement, plistDigest,
                Self.machServicePlistKeyPath,
            ],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        guard result.exitCode == 0 else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManualHelperInstallerError.authorizationFailed(
                operation: "installation",
                message: message.isEmpty ? "osascript exited with status \(result.exitCode)" : message
            )
        }
    }

    func installedHelperMatchesEmbedded(
        at installedURL: URL = URL(
            fileURLWithPath: "/Library/PrivilegedHelperTools/io.droidbridge.helper"
        )
    ) -> Bool {
        let embeddedURL = bundleURL
            .appendingPathComponent(Self.relativeDirectory)
            .appendingPathComponent(Self.helperName)
        guard let embedded = try? Data(contentsOf: embeddedURL, options: .mappedIfSafe),
              let installed = try? Data(contentsOf: installedURL, options: .mappedIfSafe)
        else {
            return false
        }
        return SHA256.hash(data: embedded) == SHA256.hash(data: installed)
    }

    /// Removes only a fully stopped helper. The root-side script refuses to
    /// unregister or delete anything while the crash-recovery journal exists.
    func uninstall() async throws {
        let result = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", Self.uninstallAppleScript],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        )
        guard result.exitCode == 0 else {
            let message = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ManualHelperInstallerError.authorizationFailed(
                operation: "removal",
                message: message.isEmpty ? "osascript exited with status \(result.exitCode)" : message
            )
        }
        let helper = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/io.droidbridge.helper")
        let plist = URL(fileURLWithPath: "/Library/LaunchDaemons/io.droidbridge.helper.plist")
        guard !FileManager.default.fileExists(atPath: helper.path),
              !FileManager.default.fileExists(atPath: plist.path)
        else {
            throw ManualHelperInstallerError.removalIncomplete
        }
    }

    private func validateHelper(at url: URL) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw ManualHelperInstallerError.invalidHelperSignature(status)
        }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(helperRequirement as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else {
            throw ManualHelperInstallerError.invalidHelperSignature(status)
        }
        let validationFlags = SecCSFlags(rawValue: (1 << 0) | (1 << 4))
        status = SecStaticCodeCheckValidity(staticCode, validationFlags, requirement)
        guard status == errSecSuccess else {
            throw ManualHelperInstallerError.invalidHelperSignature(status)
        }
    }

    private func validatePlist(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == HelperCodeRequirement.machServiceName,
              let arguments = plist["ProgramArguments"] as? [String],
              arguments == ["/Library/PrivilegedHelperTools/io.droidbridge.helper"],
              let machServices = plist["MachServices"] as? [String: Any],
              machServices[HelperCodeRequirement.machServiceName] as? Bool == true,
              plist["RunAtLoad"] as? Bool == true
        else {
            throw ManualHelperInstallerError.invalidLaunchDaemonPlist
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let appleScript = #"""
on run argv
    if (count of argv) is not 5 then error "invalid installer arguments"
    set helperSource to item 1 of argv
    set plistSource to item 2 of argv
    set helperRequirement to item 3 of argv
    set expectedPlistDigest to item 4 of argv
    set machServiceKeyPath to item 5 of argv
    set helperDestination to "/Library/PrivilegedHelperTools/io.droidbridge.helper"
    set plistDestination to "/Library/LaunchDaemons/io.droidbridge.helper.plist"
    set helperStage to helperDestination & ".new"
    set plistStage to plistDestination & ".new"
    set recoveryState to "/Library/PrivilegedHelperTools/io.droidbridge.recovery.json"
    set requirementArgument to "-R=" & helperRequirement

    set operationLock to "/Library/PrivilegedHelperTools/.io.droidbridge.operation.lock"
    set commandText to "/usr/bin/shlock -f " & quoted form of operationLock & " -p $$ || { echo 'another DroidBridge helper operation is in progress' >&2; exit 73; }"
    set commandText to commandText & "; trap 'trap - 1 2 15; exit 74' 1 2 15"
    set commandText to commandText & "; trap '/bin/rm -f " & operationLock & "' 0"
    set commandText to commandText & "; if test -e " & quoted form of recoveryState & "; then echo 'DroidBridge fail-closed recovery is active; retry Stop Tunnel before updating the helper' >&2; exit 70; fi"
    set commandText to commandText & " && /bin/rm -f " & quoted form of helperStage & " " & quoted form of plistStage
    set commandText to commandText & " && /usr/bin/install -o root -g wheel -m 0755 " & quoted form of helperSource & " " & quoted form of helperStage
    set commandText to commandText & " && /usr/bin/codesign --verify --strict " & quoted form of requirementArgument & " " & quoted form of helperStage
    set commandText to commandText & " && /usr/bin/install -o root -g wheel -m 0644 " & quoted form of plistSource & " " & quoted form of plistStage
    set commandText to commandText & " && /usr/bin/plutil -lint " & quoted form of plistStage & " >/dev/null"
    set commandText to commandText & " && test \"$(/usr/bin/shasum -a 256 " & quoted form of plistStage & " | /usr/bin/awk '{print $1}')\" = " & quoted form of expectedPlistDigest
    set commandText to commandText & " && test \"$(/usr/bin/plutil -extract Label raw -o - " & quoted form of plistStage & ")\" = io.droidbridge.helper"
    set commandText to commandText & " && test \"$(/usr/bin/plutil -extract ProgramArguments.0 raw -o - " & quoted form of plistStage & ")\" = /Library/PrivilegedHelperTools/io.droidbridge.helper"
    set commandText to commandText & " && test \"$(/usr/bin/plutil -extract " & quoted form of machServiceKeyPath & " raw -o - " & quoted form of plistStage & ")\" = true"
    set commandText to commandText & " && /bin/mv -f " & quoted form of helperStage & " " & quoted form of helperDestination
    set commandText to commandText & " && /bin/mv -f " & quoted form of plistStage & " " & quoted form of plistDestination
    set commandText to commandText & " && if /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then /bin/launchctl bootout system/io.droidbridge.helper >/dev/null 2>&1 || { echo 'could not unregister the previous DroidBridge helper' >&2; exit 71; }; fi"
    set commandText to commandText & " && if /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then echo 'the previous DroidBridge helper is still registered' >&2; exit 71; fi"
    set commandText to commandText & " && /bin/launchctl bootstrap system " & quoted form of plistDestination
    do shell script commandText with administrator privileges
end run
"""#

    private static let uninstallAppleScript = #"""
on run argv
    if (count of argv) is not 0 then error "invalid uninstaller arguments"
    set helperDestination to "/Library/PrivilegedHelperTools/io.droidbridge.helper"
    set plistDestination to "/Library/LaunchDaemons/io.droidbridge.helper.plist"
    set recoveryState to "/Library/PrivilegedHelperTools/io.droidbridge.recovery.json"
    set operationLock to "/Library/PrivilegedHelperTools/.io.droidbridge.operation.lock"
    set helperStage to helperDestination & ".new"
    set plistStage to plistDestination & ".new"

    set commandText to "/usr/bin/shlock -f " & quoted form of operationLock & " -p $$ || { echo 'another DroidBridge helper operation is in progress' >&2; exit 73; }"
    set commandText to commandText & "; trap 'trap - 1 2 15; exit 74' 1 2 15"
    set commandText to commandText & "; trap '/bin/rm -f " & operationLock & "' 0"
    set commandText to commandText & "; if test -e " & quoted form of recoveryState & "; then echo 'DroidBridge fail-closed recovery is still active; retry Stop Tunnel first' >&2; exit 70; fi"
    set commandText to commandText & "; if /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then /bin/launchctl bootout system/io.droidbridge.helper >/dev/null 2>&1 || { echo 'could not unregister DroidBridge helper; files were retained' >&2; exit 71; }; fi"
    set commandText to commandText & "; if /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then echo 'DroidBridge helper is still registered; files were retained' >&2; exit 71; fi"
    set commandText to commandText & "; if test -e " & quoted form of recoveryState & "; then if test -f " & quoted form of plistDestination & "; then /bin/launchctl bootstrap system " & quoted form of plistDestination & " >/dev/null 2>&1 || true; fi; echo 'DroidBridge became active during removal; helper was retained' >&2; exit 70; fi"
    set commandText to commandText & "; /bin/rm -f " & quoted form of helperDestination & " " & quoted form of plistDestination & " " & quoted form of helperStage & " " & quoted form of plistStage
    do shell script commandText with administrator privileges
end run
"""#
}
