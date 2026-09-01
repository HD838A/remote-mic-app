import CoreGraphics
import Testing
@testable import RemoteMic

@Suite("macOS Dictation keyboard injection")
struct MacOSDictationKeyboardInjectorTests {
    @Test func controlEdgesUseLeftControlAndReleaseEmptyFlags() {
        var posted: [(CGKeyCode, Bool, CGEventFlags)] = []
        let poster: KeyboardInjector.KeyStatePoster = { code, isDown, flags in
            posted.append((code, isDown, flags))
            return true
        }

        #expect(KeyboardInjector.setControlKeyPressed(
            true,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))
        #expect(KeyboardInjector.setControlKeyPressed(
            false,
            accessibilityTrusted: { true },
            keyStatePoster: poster
        ))

        let expected: [(CGKeyCode, Bool, CGEventFlags)] = [
            (59, true, .maskControl),
            (59, false, []),
        ]
        #expect(posted.count == expected.count)
        for (actual, expectedEvent) in zip(posted, expected) {
            #expect(actual.0 == expectedEvent.0)
            #expect(actual.1 == expectedEvent.1)
            #expect(actual.2 == expectedEvent.2)
        }
    }

    @Test func controlDownRequiresAccessibilityButReleaseIsStillAttempted() {
        var posted: [Bool] = []

        #expect(!KeyboardInjector.setControlKeyPressed(
            true,
            accessibilityTrusted: { false },
            keyStatePoster: { _, isDown, _ in
                posted.append(isDown)
                return true
            }
        ))
        #expect(KeyboardInjector.setControlKeyPressed(
            false,
            accessibilityTrusted: { false },
            keyStatePoster: { _, isDown, _ in
                posted.append(isDown)
                return true
            }
        ))
        #expect(posted == [false])
    }
}
