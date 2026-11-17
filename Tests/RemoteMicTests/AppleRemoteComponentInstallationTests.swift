import Foundation
import Testing
@testable import RemoteMic

@Suite("Siri Remote component installation")
struct AppleRemoteComponentInstallationTests {
    @Test func detectsBothPrivilegedComponentPaths() {
        let helper = "/Library/PrivilegedHelperTools/com.hd838a.SayAll.AppleRemoteHCIService"
        let plist = "/Library/LaunchDaemons/com.hd838a.SayAll.AppleRemoteHCIService.plist"
        #expect(AppleRemoteComponentInstallation.isInstalled(
            helperExists: { $0 == helper },
            launchDaemonExists: { $0 == plist }
        ))
        #expect(!AppleRemoteComponentInstallation.isInstalled(
            helperExists: { _ in false },
            launchDaemonExists: { $0 == plist }
        ))
        #expect(!AppleRemoteComponentInstallation.isInstalled(
            helperExists: { $0 == helper },
            launchDaemonExists: { _ in false }
        ))
    }
}
