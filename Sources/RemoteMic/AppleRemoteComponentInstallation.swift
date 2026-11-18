import Foundation

/// The Siri Remote component is a privileged helper plus its launch daemon.
/// App updates can install the same pair without an Installer receipt.
enum AppleRemoteComponentInstallation {
    static func snapshot(
        helperExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        launchDaemonExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> AppleRemoteComponentSnapshot {
        AppleRemoteComponentSnapshot(
            helperPresent: helperExists(
                "/Library/PrivilegedHelperTools/com.hd838a.SayAll.AppleRemoteHCIService"
            ),
            launchDaemonPresent: launchDaemonExists(
                "/Library/LaunchDaemons/com.hd838a.SayAll.AppleRemoteHCIService.plist"
            )
        )
    }

    static func isInstalled(
        helperExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        launchDaemonExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        snapshot(
            helperExists: helperExists,
            launchDaemonExists: launchDaemonExists
        ).isInstalled
    }
}

struct AppleRemoteComponentSnapshot: Equatable {
    let helperPresent: Bool
    let launchDaemonPresent: Bool

    var isInstalled: Bool {
        helperPresent && launchDaemonPresent
    }
}
