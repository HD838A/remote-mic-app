import Combine
import Foundation

/// AppKit 菜单/键盘 ⇄ SwiftUI 侧边栏的导航桥。
///
/// 沿用 `ButtonProfileImportRequestStore` 的范式：由 AppDelegate 持有并注入视图树，
/// `selectedSection` 这个 `@State` 及其既有写入路径保持不变。
/// 仅在主线程使用（写入来自菜单动作与本地按键监听，读取来自 SwiftUI）。
/// 标注 `@unchecked Sendable` 是因为 `ObservableObject` 本身没有 Sendable 约束，
/// 而 `NSMenuDelegate` / `NSEvent` 回调只会在主线程调用这里的方法。
final class SettingsNavigationStore: ObservableObject, @unchecked Sendable {
    /// 当前选中的页签（SwiftUI 上报，供菜单校验使用）。
    @Published private(set) var currentSection: SettingsSection = .mapping
    /// 当前可见页签，顺序即侧边栏顺序（SwiftUI 上报）。
    @Published private(set) var visibleSections: [SettingsSection] = []
    /// AppKit 请求切换的页签；SwiftUI 消费后清空。
    @Published private(set) var requestedSection: SettingsSection?

    func request(section: SettingsSection) {
        requestedSection = section
    }

    func consumeRequestedSection() {
        requestedSection = nil
    }

    func update(section: SettingsSection, visible: [SettingsSection]) {
        currentSection = section
        visibleSections = visible
    }
}
