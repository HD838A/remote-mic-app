import AVFoundation
import XCTest
@testable import RemoteMicIOS

final class MicrophoneStreamerTests: XCTestCase {
    func testLegacyPermissionValuesMapToStableDiagnosticNames() {
        XCTAssertEqual(MicrophoneStreamer.permissionStatus(AVAudioSession.RecordPermission.granted), .granted)
        XCTAssertEqual(MicrophoneStreamer.permissionStatus(AVAudioSession.RecordPermission.denied), .denied)
        XCTAssertEqual(
            MicrophoneStreamer.permissionStatus(AVAudioSession.RecordPermission.undetermined),
            .undetermined
        )
    }

    @available(iOS 17.0, *)
    func testModernPermissionValuesMapToTheSameDiagnosticNames() {
        XCTAssertEqual(
            MicrophoneStreamer.permissionStatus(AVAudioApplication.recordPermission.granted),
            .granted
        )
        XCTAssertEqual(
            MicrophoneStreamer.permissionStatus(AVAudioApplication.recordPermission.denied),
            .denied
        )
        XCTAssertEqual(
            MicrophoneStreamer.permissionStatus(AVAudioApplication.recordPermission.undetermined),
            .undetermined
        )
    }
}
