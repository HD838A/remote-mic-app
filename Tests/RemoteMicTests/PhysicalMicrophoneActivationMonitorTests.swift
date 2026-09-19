import Testing
@testable import RemoteMic

@Suite("Physical microphone activation monitor")
struct PhysicalMicrophoneActivationMonitorTests {
    @Test func rightCommandTogglesOncePerPress() {
        var detector = RightCommandToggleDetector()
        let firstDown = detector.handle(keyCode: 54, commandPressed: true)
        let repeatedDown = detector.handle(keyCode: 54, commandPressed: true)
        let firstUp = detector.handle(keyCode: 54, commandPressed: false)
        let secondDown = detector.handle(keyCode: 54, commandPressed: true)
        #expect(firstDown)
        #expect(!repeatedDown)
        #expect(!firstUp)
        #expect(secondDown)
    }

    @Test func otherCommandKeysNeverToggle() {
        var detector = RightCommandToggleDetector()
        let down = detector.handle(keyCode: 55, commandPressed: true)
        let up = detector.handle(keyCode: 55, commandPressed: false)
        #expect(!down)
        #expect(!up)
    }
}
