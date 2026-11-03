import Foundation
import Testing
@testable import RemoteMic

/// 「按键手势」学习结果的保留规则：
/// 学完就按机型存下来，切换页面、换遥控器、重开 App 之后仍然显示「学习完成」，
/// 但它不改识别时间本身——识别时间仍然只在点「保存」后生效。
@Suite("Gesture learning persistence")
struct GestureLearningPersistenceTests {
    private func makeSettings() throws -> (AppSettings, UserDefaults, String) {
        let name = "SayAll.GestureLearning.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (AppSettings(defaults: defaults), defaults, name)
    }

    private static let learned = StoredButtonGestureLearning(
        singleClickMilliseconds: 165,
        doubleClickMilliseconds: 90,
        longPressMilliseconds: 674,
        suggestedDoubleClickMilliseconds: 150,
        suggestedLongPressMilliseconds: 650
    )

    /// 学习结果可以跨重启保留，这是「显示未开始」的直接修复点。
    @Test func learningSurvivesRelaunch() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.setButtonGestureLearning(Self.learned, for: .rc003)
        #expect(settings.buttonGestureLearning(for: .rc003) == Self.learned)

        let relaunched = AppSettings(defaults: defaults)
        #expect(relaunched.buttonGestureLearning(for: .rc003) == Self.learned)
    }

    @Test func learningIsKeptPerModel() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        settings.setButtonGestureLearning(Self.learned, for: .rc003)
        #expect(settings.buttonGestureLearning(for: .unknown) == nil)
        #expect(settings.buttonGestureLearningsByModel.count == 1)
    }

    /// 学习只写展示用的样本值，识别时间必须还是原来的——不能借学习偷偷改用户设置。
    @Test func learningDoesNotChangeTheSavedTiming() throws {
        let (settings, defaults, suite) = try makeSettings()
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = settings.buttonGestureTiming(for: .rc003)
        settings.setButtonGestureLearning(Self.learned, for: .rc003)

        #expect(settings.buttonGestureTiming(for: .rc003) == original)
    }

    /// 已完成的学习不能被「离开页面」这类取消清掉。
    @Test func completedLearningIsNotCancellable() {
        let status = RemoteButtonGestureLearningStatus.restored(from: Self.learned, model: .rc003)
        #expect(status.step == .complete)
        #expect(!status.isCancellable)
        #expect(status.singleClickMilliseconds == 165)
        #expect(status.doubleClickMilliseconds == 90)
        #expect(status.longPressMilliseconds == 674)
    }

    /// 进行中的学习仍然必须可取消，否则退不出学习流程。
    @Test func activeLearningIsCancellable() {
        let status = RemoteButtonGestureLearningStatus(
            step: .doubleClick,
            model: .rc003,
            button: .down
        )
        #expect(status.isCancellable)
    }

    @Test func idleLearningIsNotCancellable() {
        #expect(!RemoteButtonGestureLearningStatus().isCancellable)
    }
}
