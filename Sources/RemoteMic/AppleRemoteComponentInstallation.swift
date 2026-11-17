import Foundation

/// The Siri Remote component is a privileged helper plus its launch daemon.
/// App updates can install the same pair without an Installer receipt.
enum AppleRemoteComponentInstallation {
    static func isInstalled(
        helperExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        launchDaemonExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        helperExists("/Library/PrivilegedHelperTools/com.hd838a.SayAll.AppleRemoteHCIService")
            && launchDaemonExists("/Library/LaunchDaemons/com.hd838a.SayAll.AppleRemoteHCIService.plist")
    }
}
