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
        let snapshot = AppleRemoteComponentInstallation.snapshot(
            helperExists: { $0 == helper },
            launchDaemonExists: { _ in false }
        )
        #expect(snapshot.helperPresent)
        #expect(!snapshot.launchDaemonPresent)
        #expect(!snapshot.isInstalled)
    }

    @Test func diagnosticStateContainsOnlyNonSensitiveInstallationFacts() {
        let state = SiriRemoteComponentDiagnosticState(
            buildSupported: true,
            installerReceiptPresent: true,
            helperPresent: false,
            launchDaemonPresent: false
        )
        #expect(state.logFields ==
            "build_supported=true installer_receipt_present=true " +
                "helper_present=false launch_daemon_present=false " +
                "component_installed=false"
        )
    }
}
