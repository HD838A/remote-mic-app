import AppKit
import Combine
import Foundation

/// 一次动作执行的最终结果分类。
///
/// 分类只描述“用户需要做什么”，不描述内部实现。日志与复制诊断使用 rawValue，
/// 屏幕文案由 `ActionFeedbackStrings` 统一给出，避免第二套错误语言。
enum ActionFeedbackFailureKind: String, CaseIterable, Hashable, Sendable {
    case permissionDenied = "permission_denied"
    case targetMissing = "target_missing"
    case targetUnavailable = "target_unavailable"
    case shortcutNotDelivered = "shortcut_not_delivered"
    case configurationUnavailable = "configuration_unavailable"
    case executionFailed = "execution_failed"
    case scriptFailed = "script_failed"
    case unknownResult = "unknown_result"
    case notStarted = "not_started"

    /// 没有更具体建议时的默认动作。
    var defaultAction: ActionFeedbackAction {
        switch self {
        case .permissionDenied:
            return .openSystemSettings
        case .targetMissing, .configurationUnavailable:
            return .reselectAction
        case .targetUnavailable:
            return .openApplication
        case .executionFailed, .scriptFailed, .unknownResult, .notStarted:
            return .retry
        case .shortcutNotDelivered:
            return .retry
        }
    }
}

enum ActionFeedbackResult: Equatable, Sendable {
    case success
    case cancelled
    case timedOut
    case failure(ActionFeedbackFailureKind)

    /// 日志与诊断中的稳定分类，不本地化。
    var category: String {
        switch self {
        case .success: return "success"
        case .cancelled: return "cancelled"
        case .timedOut: return "timed_out"
        case let .failure(kind): return kind.rawValue
        }
    }

    var failureKind: ActionFeedbackFailureKind? {
        if case let .failure(kind) = self { return kind }
        return nil
    }
}

enum ActionFeedbackAction: String, CaseIterable, Hashable, Sendable {
    case openSystemSettings = "open_system_settings"
    case openApplication = "open_application"
    case reselectAction = "reselect_action"
    case retry
}

/// 当前结果能提供的可执行动作。闭包只在主线程执行。
///
/// 标记 `@unchecked Sendable` 是为了能把结果从执行回调投递到主线程的
/// `ActionFeedbackCenter`；所有闭包最终都由该中心在主线程调用。
struct ActionFeedbackActionHandlers: @unchecked Sendable {
    var openApplication: (@MainActor () -> Void)? = nil
    var reselectAction: (@MainActor () -> Void)? = nil
    var retry: (@MainActor () -> Void)? = nil

    func handler(for action: ActionFeedbackAction) -> (@MainActor () -> Void)? {
        switch action {
        case .openApplication: return openApplication
        case .reselectAction: return reselectAction
        case .retry: return retry
        case .openSystemSettings: return nil
        }
    }
}

/// 一条动作结果。`actionName` 只用于屏幕显示和合并，不进入日志或复制诊断。
struct ActionFeedbackEvent: Sendable {
    let operationID: String
    let actionID: String
    let actionName: String
    let result: ActionFeedbackResult
    let elapsedMilliseconds: Int
    let stepIndex: Int?
    let stepCount: Int?
    let timestamp: Date
    let presentsSuccess: Bool
    let presentsFailure: Bool
    let actionOverride: ActionFeedbackAction?

    init(
        operationID: String,
        actionID: String,
        actionName: String,
        result: ActionFeedbackResult,
        elapsedMilliseconds: Int,
        stepIndex: Int? = nil,
        stepCount: Int? = nil,
        timestamp: Date = Date(),
        presentsSuccess: Bool = true,
        presentsFailure: Bool = true,
        actionOverride: ActionFeedbackAction? = nil
    ) {
        self.operationID = operationID
        self.actionID = actionID
        self.actionName = actionName
        self.result = result
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.stepIndex = stepIndex
        self.stepCount = stepCount
        self.timestamp = timestamp
        self.presentsSuccess = presentsSuccess
        self.presentsFailure = presentsFailure
        self.actionOverride = actionOverride
    }
}

/// 屏幕上的一条结果。成功和失败共用同一个气泡组件，字段按需要留空。
struct ActionFeedbackPresentation: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case success
        case failure
    }

    let id: UUID
    let kind: Kind
    let operationID: String
    let title: String
    let context: String?
    let detail: String?
    let action: ActionFeedbackAction?
    let actionTitle: String?
    let copyTitle: String?
    let copiedTitle: String?
    let diagnostics: String?
    let count: Int
    let announces: Bool
    let accessibilityAnnouncement: String?
    let errorPrefix: String?
    let closeLabel: String?
}

/// 双语文案与格式。由调用方按当前 App 语言构建，中心只负责组合和计时。
struct ActionFeedbackStrings: Sendable {
    let locale: Locale
    let successTitleFormat: String
    let successRepeatFormat: String
    let successMultipleFormat: String
    let failureTitleFormat: String
    let timeoutTitleFormat: String
    let timeoutContext: String
    let timeoutDetail: String
    let stepFormat: String
    let stepOfFormat: String
    let stepsFormat: String
    let contexts: [ActionFeedbackFailureKind: String]
    let details: [ActionFeedbackFailureKind: String]
    let actionTitles: [ActionFeedbackAction: String]
    let copyDiagnosticsTitle: String
    let copiedTitle: String
    let diagnosticsNote: String
    let errorPrefix: String
    let closeLabel: String

    init(localization: LocalizationStore) {
        locale = localization.locale
        func text(_ key: String) -> String { localization.text(key) }
        successTitleFormat = text("action_feedback.success.title")
        successRepeatFormat = text("action_feedback.success.repeat")
        successMultipleFormat = text("action_feedback.success.multiple")
        failureTitleFormat = text("action_feedback.failure.title")
        timeoutTitleFormat = text("action_feedback.timeout.title")
        timeoutContext = text("action_feedback.timeout.context")
        timeoutDetail = text("action_feedback.timeout.detail")
        stepFormat = text("action_feedback.step")
        stepOfFormat = text("action_feedback.step_of")
        stepsFormat = text("action_feedback.steps")
        contexts = Dictionary(uniqueKeysWithValues: ActionFeedbackFailureKind.allCases.map { kind in
            (kind, text("action_feedback.failure.\(kind.rawValue).context"))
        })
        details = Dictionary(uniqueKeysWithValues: ActionFeedbackFailureKind.allCases.map { kind in
            (kind, text("action_feedback.failure.\(kind.rawValue).detail"))
        })
        actionTitles = [
            .openSystemSettings: text("notice.action.open_system_settings"),
            .openApplication: text("action_feedback.action.open_application"),
            .reselectAction: text("action_feedback.action.reselect"),
            .retry: text("notice.action.retry"),
        ]
        copyDiagnosticsTitle = text("action_feedback.action.copy_diagnostics")
        copiedTitle = text("action_feedback.action.copied")
        diagnosticsNote = text("action_feedback.diagnostics.note")
        errorPrefix = text("notice.accessibility.error_prefix")
        closeLabel = text("notice.accessibility.dismiss")
    }

    func format(_ template: String, _ arguments: String...) -> String {
        String(format: template, locale: locale, arguments: arguments)
    }
}

/// 复制诊断的最小内容：只含排障字段，不含动作名、快捷键、脚本、输入或目标 App 内容。
enum ActionFeedbackDiagnostics {
    static func text(
        event: ActionFeedbackEvent,
        strings: ActionFeedbackStrings,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo
    ) -> String {
        let info = bundle.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let os = processInfo.operatingSystemVersion
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        let step: String
        if let index = event.stepIndex, let count = event.stepCount {
            step = "\(index) / \(count)"
        } else if let count = event.stepCount {
            step = "unknown / \(count)"
        } else {
            step = "unknown"
        }
        return """
        SayAll \(version) (\(build)) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        time \(timeFormatter.string(from: event.timestamp))
        operation \(event.operationID)
        action \(event.actionID)
        step \(step)
        category \(event.result.category)
        elapsed \(event.elapsedMilliseconds) ms

        \(strings.diagnosticsNote)
        """
    }
}

/// App 级 HUD 的唯一状态源。只做合并、优先级、计时和复制，不自己创建窗口；
/// `ActionFeedbackWindowCoordinator` 观察它并维护真实浮层。
@MainActor
final class ActionFeedbackCenter: ObservableObject {
    static let shared = ActionFeedbackCenter()

    @Published private(set) var presentation: ActionFeedbackPresentation?
    @Published private(set) var copiedPresentationID: UUID?

    private struct LastPresented {
        let kind: ActionFeedbackPresentation.Kind
        let actionID: String
        let actionName: String
        let failureKind: ActionFeedbackFailureKind?
        let timedOut: Bool
        let multipleActions: Bool
        let count: Int
        let at: Date
    }

    private let now: () -> Date
    private let successDuration: TimeInterval
    private let failureDuration: TimeInterval
    private let mergeWindow: TimeInterval
    private let copiedDuration: TimeInterval
    private let log: (String) -> Void
    private let pasteboardWriter: (String) -> Void

    private var lastPresented: LastPresented?
    private var dismissTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?
    private var dismissDeadline: Date?
    private var remainingDismissal: TimeInterval?
    private var isHovering = false
    private var eventHandlers: [ActionFeedbackAction: @MainActor () -> Void] = [:]
    private var standardHandlers: [ActionFeedbackAction: @MainActor () -> Void] = [:]

    init(
        now: @escaping () -> Date = Date.init,
        successDuration: TimeInterval = 1.3,
        failureDuration: TimeInterval = 12,
        mergeWindow: TimeInterval = 2,
        copiedDuration: TimeInterval = 2,
        log: @escaping (String) -> Void = { AppLogger.shared.write($0) },
        pasteboardWriter: @escaping (String) -> Void = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    ) {
        self.now = now
        self.successDuration = successDuration
        self.failureDuration = failureDuration
        self.mergeWindow = mergeWindow
        self.copiedDuration = copiedDuration
        self.log = log
        self.pasteboardWriter = pasteboardWriter
    }

    /// 由 AppDelegate 配置。权限设置与“重新选择”不依赖某一按键，所以是标准动作。
    func configureStandardActions(
        openSystemSettings: @escaping @MainActor () -> Void,
        reselectAction: @escaping @MainActor () -> Void
    ) {
        standardHandlers[.openSystemSettings] = openSystemSettings
        standardHandlers[.reselectAction] = reselectAction
    }

    func record(
        _ event: ActionFeedbackEvent,
        strings: ActionFeedbackStrings,
        handlers: ActionFeedbackActionHandlers = ActionFeedbackActionHandlers()
    ) {
        let timestamp = now()
        let step = event.stepIndex.map(String.init) ?? "unknown"
        let steps = event.stepCount.map(String.init) ?? "unknown"
        var count = 0
        var state = "ignored"

        switch event.result {
        case .cancelled:
            state = "cancelled"

        case .success:
            if !event.presentsSuccess {
                state = "disabled_success"
                break
            }
            if presentation?.kind == .failure {
                state = "suppressed_by_failure"
                break
            }
            let merged = mergedSuccess(event: event, at: timestamp)
            count = merged.count
            let newPresentation = makeSuccessPresentation(
                event: event,
                count: merged.count,
                multipleActions: merged.multipleActions,
                strings: strings
            )
            install(
                newPresentation,
                handlers: handlers,
                duration: successDuration
            )
            lastPresented = LastPresented(
                kind: .success,
                actionID: event.actionID,
                actionName: event.actionName,
                failureKind: nil,
                timedOut: false,
                multipleActions: merged.multipleActions,
                count: merged.count,
                at: timestamp
            )
            state = merged.count > 1 ? "merged" : "shown"

        case .timedOut, .failure:
            if !event.presentsFailure {
                state = "disabled_failure"
                break
            }
            let mergedCount = mergedFailure(event: event, at: timestamp)
            count = mergedCount
            let visibleBefore = presentation != nil
            let newPresentation = makeFailurePresentation(
                event: event,
                count: mergedCount,
                announces: mergedCount == 1 || !visibleBefore,
                strings: strings,
                handlers: handlers
            )
            install(
                newPresentation,
                handlers: handlers,
                duration: failureDuration
            )
            lastPresented = LastPresented(
                kind: .failure,
                actionID: event.actionID,
                actionName: event.actionName,
                failureKind: event.result.failureKind,
                timedOut: event.result == .timedOut,
                multipleActions: false,
                count: mergedCount,
                at: timestamp
            )
            state = mergedCount > 1 ? "merged" : "shown"
        }

        log(
            "ACTION FEEDBACK operation_id=\(event.operationID) " +
                "action_id=\(event.actionID) result=\(event.result.category) " +
                "step=\(step) steps=\(steps) elapsed_ms=\(event.elapsedMilliseconds) " +
                "count=\(count) presentation=\(state)"
        )
    }

    func setHovering(_ hovering: Bool) {
        guard presentation?.kind == .failure, hovering != isHovering else { return }
        if hovering {
            isHovering = true
            if let deadline = dismissDeadline {
                remainingDismissal = max(0, deadline.timeIntervalSince(now()))
            }
            dismissTask?.cancel()
            dismissTask = nil
            dismissDeadline = nil
        } else {
            isHovering = false
            let remaining = remainingDismissal ?? failureDuration
            remainingDismissal = nil
            if remaining <= 0.01 {
                dismiss()
            } else {
                scheduleDismissal(after: remaining)
            }
        }
    }

    func copyDiagnostics() {
        guard let presentation,
              presentation.kind == .failure,
              let diagnostics = presentation.diagnostics
        else { return }
        pasteboardWriter(diagnostics)
        copiedPresentationID = presentation.id
        copyResetTask?.cancel()
        let presentationID = presentation.id
        let resetNanoseconds = UInt64(max(0, copiedDuration) * 1_000_000_000)
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: resetNanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.copiedPresentationID == presentationID else { return }
            self.copiedPresentationID = nil
        }
        log(
            "ACTION FEEDBACK operation_id=\(presentation.operationID) " +
                "phase=copied result=completed"
        )
    }

    func perform(_ action: ActionFeedbackAction) {
        guard let handler = handler(for: action) else { return }
        log(
            "ACTION FEEDBACK operation_id=\(presentation?.operationID ?? "unknown") " +
                "phase=action_requested action_id=\(action.rawValue)"
        )
        dismiss()
        handler()
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        copyResetTask?.cancel()
        copyResetTask = nil
        dismissDeadline = nil
        remainingDismissal = nil
        isHovering = false
        presentation = nil
        copiedPresentationID = nil
        eventHandlers = [:]
    }

    /// 仅测试使用：清掉上一次合并状态，模拟新进程。
    func resetMergeStateForTesting() {
        lastPresented = nil
        dismiss()
        standardHandlers = [:]
    }

    private func mergedSuccess(
        event: ActionFeedbackEvent,
        at timestamp: Date
    ) -> (count: Int, multipleActions: Bool) {
        guard let lastPresented,
              lastPresented.kind == .success,
              timestamp.timeIntervalSince(lastPresented.at) <= min(mergeWindow, successDuration)
        else { return (1, false) }
        let sameAction = lastPresented.actionID == event.actionID
            && lastPresented.actionName == event.actionName
        return (
            lastPresented.count + 1,
            lastPresented.multipleActions || !sameAction
        )
    }

    private func mergedFailure(
        event: ActionFeedbackEvent,
        at timestamp: Date
    ) -> Int {
        guard let lastPresented,
              lastPresented.kind == .failure,
              timestamp.timeIntervalSince(lastPresented.at) <= mergeWindow,
              lastPresented.actionID == event.actionID,
              lastPresented.failureKind == event.result.failureKind,
              lastPresented.timedOut == (event.result == .timedOut)
        else { return 1 }
        return lastPresented.count + 1
    }

    private func makeSuccessPresentation(
        event: ActionFeedbackEvent,
        count: Int,
        multipleActions: Bool,
        strings: ActionFeedbackStrings
    ) -> ActionFeedbackPresentation {
        let title: String
        if multipleActions {
            title = strings.format(strings.successMultipleFormat, String(count))
        } else if count > 1 {
            title = strings.format(
                strings.successRepeatFormat,
                event.actionName,
                String(count)
            )
        } else {
            title = strings.format(strings.successTitleFormat, event.actionName)
        }
        return ActionFeedbackPresentation(
            id: UUID(),
            kind: .success,
            operationID: event.operationID,
            title: title,
            context: nil,
            detail: nil,
            action: nil,
            actionTitle: nil,
            copyTitle: nil,
            copiedTitle: nil,
            diagnostics: nil,
            count: count,
            announces: false,
            accessibilityAnnouncement: nil,
            errorPrefix: nil,
            closeLabel: nil
        )
    }

    private func makeFailurePresentation(
        event: ActionFeedbackEvent,
        count: Int,
        announces: Bool,
        strings: ActionFeedbackStrings,
        handlers: ActionFeedbackActionHandlers
    ) -> ActionFeedbackPresentation {
        let isTimeout = event.result == .timedOut
        let kind = event.result.failureKind
        let baseTitle = strings.format(
            isTimeout ? strings.timeoutTitleFormat : strings.failureTitleFormat,
            event.actionName
        )
        let title = count > 1 ? "\(baseTitle) ×\(count)" : baseTitle
        let context = isTimeout
            ? strings.timeoutContext
            : (kind.flatMap { strings.contexts[$0] } ?? "")
        let detail = isTimeout
            ? strings.timeoutDetail
            : (kind.flatMap { strings.details[$0] } ?? "")
        let stepText: String?
        if let index = event.stepIndex, let count = event.stepCount {
            stepText = strings.format(strings.stepOfFormat, String(index), String(count))
        } else if let index = event.stepIndex {
            stepText = strings.format(strings.stepFormat, String(index))
        } else if let count = event.stepCount {
            stepText = strings.format(strings.stepsFormat, String(count))
        } else {
            stepText = nil
        }
        let fullContext = [stepText, context]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        let candidate = event.actionOverride ?? kind?.defaultAction
        let action = candidate.flatMap { action in
            handler(for: action, handlers: handlers) == nil ? nil : action
        }
        let actionTitle = action.flatMap { strings.actionTitles[$0] }
        let announcement = [strings.errorPrefix + title, fullContext, detail]
            .filter { !$0.isEmpty }
            .joined(separator: "。")
        return ActionFeedbackPresentation(
            id: UUID(),
            kind: .failure,
            operationID: event.operationID,
            title: title,
            context: fullContext,
            detail: detail,
            action: action,
            actionTitle: actionTitle,
            copyTitle: strings.copyDiagnosticsTitle,
            copiedTitle: strings.copiedTitle,
            diagnostics: ActionFeedbackDiagnostics.text(event: event, strings: strings),
            count: count,
            announces: announces,
            accessibilityAnnouncement: announcement,
            errorPrefix: strings.errorPrefix,
            closeLabel: strings.closeLabel
        )
    }

    private func install(
        _ presentation: ActionFeedbackPresentation,
        handlers: ActionFeedbackActionHandlers,
        duration: TimeInterval
    ) {
        self.presentation = presentation
        copiedPresentationID = nil
        copyResetTask?.cancel()
        copyResetTask = nil
        eventHandlers = [:]
        if let handler = handlers.openApplication {
            eventHandlers[.openApplication] = handler
        }
        if let handler = handlers.reselectAction {
            eventHandlers[.reselectAction] = handler
        }
        if let handler = handlers.retry {
            eventHandlers[.retry] = handler
        }
        if isHovering, presentation.kind == .failure {
            dismissTask?.cancel()
            dismissTask = nil
            dismissDeadline = nil
            remainingDismissal = duration
        } else {
            isHovering = false
            remainingDismissal = nil
            scheduleDismissal(after: duration)
        }
    }

    private func scheduleDismissal(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissDeadline = now().addingTimeInterval(seconds)
        let presentationID = presentation?.id
        dismissTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, self.presentation?.id == presentationID else { return }
            self.dismiss()
        }
    }

    private func handler(
        for action: ActionFeedbackAction,
        handlers: ActionFeedbackActionHandlers
    ) -> (@MainActor () -> Void)? {
        if let handler = handlers.handler(for: action) { return handler }
        return standardHandlers[action]
    }

    private func handler(for action: ActionFeedbackAction) -> (@MainActor () -> Void)? {
        eventHandlers[action] ?? standardHandlers[action]
    }
}

/// 屏幕底部居中的纯布局。气泡下缘距可见区域底部 56pt；窗口自身还带 16pt
/// 透明内边距用于阴影，所以面板原点要再减掉这段 padding。
enum ActionFeedbackLayout {
    static let bubbleBottomInset: CGFloat = 56
    static let contentPadding: CGFloat = 16
    static let edgeMargin: CGFloat = 8

    static func origin(
        visibleFrame: CGRect,
        panelSize: CGSize,
        bubbleBottomInset: CGFloat = ActionFeedbackLayout.bubbleBottomInset,
        contentPadding: CGFloat = ActionFeedbackLayout.contentPadding
    ) -> CGPoint {
        let preferredX = visibleFrame.midX - panelSize.width / 2
        let minimumX = visibleFrame.minX + edgeMargin
        let maximumX = visibleFrame.maxX - panelSize.width - edgeMargin
        let x = maximumX >= minimumX
            ? min(max(preferredX, minimumX), maximumX)
            : minimumX
        let preferredY = visibleFrame.minY + bubbleBottomInset - contentPadding
        let y = max(visibleFrame.minY + edgeMargin, preferredY)
        return CGPoint(x: x, y: y)
    }
}

/// 私有组合动作通过公开的 `executionEvents` 上报最终 terminal。
/// 这里只映射结果，不读取私有模块的实现。
enum ActionFeedbackMacroClassifier {
    static func result(forTerminal terminal: String) -> ActionFeedbackResult {
        switch terminal {
        case "completed":
            return .success
        case "cancelled":
            return .cancelled
        case "timedOut":
            return .timedOut
        case "permissionDenied":
            return .failure(.permissionDenied)
        case "missingDependency", "missing_dependency", "invalidMacro":
            return .failure(.configurationUnavailable)
        case "script_exit_nonzero", "script_launch_failed":
            return .failure(.scriptFailed)
        case "completedWithUnknownResult":
            return .failure(.unknownResult)
        case "alreadyRunning":
            return .failure(.notStarted)
        case "stepFailed":
            return .failure(.executionFailed)
        default:
            return .failure(.unknownResult)
        }
    }
}

/// 异步打开 App 的回调可能晚于同步返回值到达；只允许最终结果被消费一次。
final class ActionFeedbackCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didFinish = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return false }
        didFinish = true
        return true
    }
}

extension ConfiguredButtonAction {
    /// 成功提示只覆盖一次操作一个结果的动作。方向键、滚动、音量、按住连发和
    /// App 切换会话由用户连续操作，逐次弹 HUD 会挡住目标 App，因此不显示成功提示。
    var showsActionSuccessFeedback: Bool {
        guard action != .disabled, !action.isAppInternal else { return false }
        if action == .combinationAction { return true }
        if action == .appSwitcher { return false }
        return !allowsSingleClickRepeat
            && holdableKey == nil
            && !action.isPageScroll
    }
}

extension ButtonAction {
    /// 打开 App 与组合动作由各自执行器处理权限；其余动作都需要辅助功能注入。
    var requiresAccessibilityForAction: Bool {
        guard !isAppInternal, self != .disabled else { return false }
        if presetApplication != nil { return false }
        switch self {
        case .openCustomApplication, .combinationAction:
            return false
        default:
            return true
        }
    }
}
