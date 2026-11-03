import Foundation
import Testing
@testable import RemoteMic

/// 「APP 适配」的回归对象固定使用系统自带的文本编辑：它一定存在于每台 Mac 上，
/// 不会像第三方 App 那样因为没装而让用例失效。
@Suite("Custom application profile lifecycle")
struct CustomApplicationProfileLifecycleTests {
    private static let textEditBundleID = "com.apple.TextEdit"

    private static func textEditProfile() -> CustomApplicationProfile {
        CustomApplicationProfile(
            displayName: "文本编辑",
            bundleIdentifier: textEditBundleID,
            applicationPath: "/System/Applications/TextEdit.app",
            focusStrategy: .recordedAccessibility,
            accessibilityTarget: AccessibilityFocusTarget(
                role: "AXTextArea",
                identifier: "First Text View",
                title: "",
                description: "",
                help: "",
                placeholder: "",
                context: "_NS:8 _NS:34",
                windowTitle: "未命名",
                normalizedFrame: NormalizedAccessibilityFrame(
                    x: 0.43, y: 0.0, width: 0.57, height: 0.96
                )
            )
        )
    }

    private func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let name = "SayAll.ApplicationProfileLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppSettings(defaults: defaults), defaults, name)
    }

    @Test func removalDeletesOnlyTheRequestedProfile() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let textEdit = Self.textEditProfile()
        let other = CustomApplicationProfile(
            displayName: "另一个 APP",
            bundleIdentifier: "com.example.other",
            applicationPath: "/Applications/Other.app"
        )
        settings.addCustomApplicationProfile(textEdit)
        settings.addCustomApplicationProfile(other)

        settings.removeCustomApplicationProfile(id: textEdit.id)

        #expect(settings.customApplicationProfile(id: textEdit.id) == nil)
        #expect(settings.customApplicationProfiles.map(\.id) == [other.id])
    }

    @Test func removalIsPersistedAcrossRelaunch() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let textEdit = Self.textEditProfile()
        settings.addCustomApplicationProfile(textEdit)
        settings.removeCustomApplicationProfile(id: textEdit.id)

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.customApplicationProfiles.isEmpty)
    }

    @Test func removalClearsThePendingVerificationMarker() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let textEdit = Self.textEditProfile()
        settings.addCustomApplicationProfile(textEdit)
        defaults.set([textEdit.id.uuidString], forKey: "portableTransferPendingApplications")
        #expect(settings.portableApplicationRequiresVerification(textEdit))

        settings.removeCustomApplicationProfile(id: textEdit.id)

        #expect(settings.portablePendingApplications.isEmpty)
    }

    @Test func removingAnUnknownProfileChangesNothing() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let textEdit = Self.textEditProfile()
        settings.addCustomApplicationProfile(textEdit)

        settings.removeCustomApplicationProfile(id: UUID())

        #expect(settings.customApplicationProfiles.map(\.id) == [textEdit.id])
    }

    /// 学到的输入框只保留结构性描述，不保存输入内容。这条是硬边界，删掉实现前先改规范。
    @Test func recordedTargetKeepsStructureOnly() throws {
        let textEdit = Self.textEditProfile()
        let target = try #require(textEdit.accessibilityTarget)
        #expect(target.role == "AXTextArea")
        #expect((target.normalizedFrame?.width ?? 0) > 0)
        #expect(textEdit.focusShortcut == nil)
    }
}
