import Foundation
import SwiftUI

/// 提示的动作：文案由组件统一给，业务只负责“点下去做什么”。
struct NoticeAction {
    let title: String
    let perform: @MainActor () -> Void

    init(title: String, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// 标准动作。按钮文案固定在这些 key 上，业务侧不能各写一套。
enum NoticeActionKind: String, CaseIterable {
    case reopenCommonPhrases = "reopen_common_phrases"
    case openSystemSettings = "open_system_settings"
    case retry = "retry"
    case dismiss = "dismiss"

    var titleKey: String {
        "notice.action.\(rawValue)"
    }
}

extension NoticeAction {
    static func standard(
        _ kind: NoticeActionKind,
        perform: @escaping @MainActor () -> Void
    ) -> NoticeAction {
        NoticeAction(title: noticeLocalized(kind.titleKey), perform: perform)
    }
}

/// 没有锚点时气泡落在哪。有锚点时锚点优先，这个值被忽略。
enum NoticePosition: String, CaseIterable {
    /// 内容区顶部，距边 12pt。
    case top
    /// 宿主内容区正中，默认。
    case center
    /// 内容区底部，距边 12pt。
    case bottom
}

/// 一条提示。
struct Notice: Identifiable {
    enum Dismissal: Equatable {
        /// 若干秒后自动消失。
        case automatic(TimeInterval)
        /// 必须由用户关闭（Esc、关闭按钮或动作）。
        case manual
    }

    let id: UUID
    var tier: NoticeTier
    var title: String
    var text: String?
    var action: NoticeAction?
    var dismissal: Dismissal
    /// 没有锚点时的落点。默认居中。
    var position: NoticePosition
    /// nil 表示不锚定；有值表示钉在对应元素上，此时 `position` 不生效。
    var anchor: NoticeAnchorID?
    /// 引导类提示只出现一次：写入这个 key 后不再显示。
    var seenKey: String?
    /// 是否给关闭按钮。状态类提示描述的是仍然存在的事实，关掉会误导。
    var dismissible: Bool

    init(
        id: UUID = UUID(),
        tier: NoticeTier,
        title: String,
        text: String? = nil,
        action: NoticeAction? = nil,
        dismissal: Dismissal? = nil,
        position: NoticePosition = .center,
        anchor: NoticeAnchorID? = nil,
        seenKey: String? = nil,
        dismissible: Bool = true
    ) {
        self.id = id
        self.tier = tier
        self.title = title
        self.text = text
        self.action = action
        self.dismissal = dismissal ?? Self.defaultDismissal(for: tier)
        self.position = position
        self.anchor = anchor
        self.seenKey = seenKey
        self.dismissible = dismissible
    }

    /// 默认停留时长按档位给；错误默认 6 秒，需要用户必须处理时传 `.manual`。
    static func defaultDismissal(for tier: NoticeTier) -> Dismissal {
        switch tier {
        case .tip: return .automatic(2.4)
        case .warning: return .automatic(4.0)
        case .error: return .automatic(6.0)
        }
    }
}

/// 提示中心：单实例、优先级替换、计时、`seenKey` 记账。
///
/// 视图层用 `noticeHost()` 挂一次即可；业务侧只调 `show(_:)`。
@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    @Published private(set) var current: Notice?

    private let defaults: UserDefaults
    private var dismissTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    deinit {
        dismissTask?.cancel()
    }

    /// 展示一条提示。已经被 `seenKey` 记过的直接忽略。
    func show(_ notice: Notice) {
        if let key = notice.seenKey {
            guard !defaults.bool(forKey: key) else { return }
            // 用户看到即算看过；手动关掉也走同一条路径，不会重复打扰。
            defaults.set(true, forKey: key)
        }

        guard shouldReplaceCurrent(with: notice) else { return }

        dismissTask?.cancel()
        current = notice
        scheduleDismissal(for: notice)
    }

    /// 关闭当前提示。传入 id 时只关闭匹配的那条，避免延迟任务误杀后来的提示。
    func dismiss(_ id: UUID? = nil) {
        guard let current else { return }
        if let id, current.id != id { return }
        dismissTask?.cancel()
        dismissTask = nil
        self.current = nil
    }

    /// 更高优先级才能顶掉当前提示；错误永远可以顶掉。
    private func shouldReplaceCurrent(with notice: Notice) -> Bool {
        guard let current else { return true }
        if notice.tier == .error { return true }
        if current.tier == .error { return false }
        return notice.tier.priority >= current.tier.priority
    }

    private func scheduleDismissal(for notice: Notice) {
        guard case .automatic(let seconds) = notice.dismissal else { return }
        dismissTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.dismiss(notice.id)
        }
    }
}
