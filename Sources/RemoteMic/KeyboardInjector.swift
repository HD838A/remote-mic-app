import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum KeyboardInjector {
    typealias ApplicationOpener = (
        URL,
        PresetApplication,
        @escaping (pid_t?, Error?) -> Void
    ) -> Void
    typealias ApplicationFocuser = (URL, PresetApplication, pid_t, UInt64) -> Void
    typealias FrontmostApplicationProvider = () -> (bundleIdentifier: String, processIdentifier: pid_t)?
    typealias CustomApplicationOpener = (
        URL,
        CustomApplicationProfile,
        @escaping (pid_t?, Error?) -> Void
    ) -> Void
    typealias CustomApplicationFocuser = (CustomApplicationProfile, pid_t, UInt64) -> Void
    typealias CmuxCommandRunner = (URL, [String], TimeInterval) -> CmuxCommandResult
    typealias KeyPoster = (CGKeyCode, CGEventFlags) -> Void
    typealias KeyStatePoster = (CGKeyCode, Bool, CGEventFlags) -> Bool
    typealias ScrollPoster = (Int32) -> Void
    typealias SystemKeyPoster = (Int32) -> Void

    /// Dock 进程当前拥有的窗口数量。
    ///
    /// 切换器打开时 Dock 会多出一个窗口，这是判断“切换器是否还开着”最稳的信号：
    /// 辅助功能里的切换器列表在部分系统上会一直存在（即使切换器没开），
    /// 也会在切换器开着时随机消失，不能用来判断。
    static func dockWindowCount() -> Int {
        guard let dock = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.dock"
        ).first else { return 0 }
        let windows = (
            CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        ) ?? []
        let dockIdentifier = Int(dock.processIdentifier)
        return windows.filter {
            (($0[kCGWindowOwnerPID as String] as? NSNumber)?.intValue ?? -1) == dockIdentifier
        }.count
    }

    struct ApplicationVisibilitySnapshot: Equatable {
        let bundleIdentifier: String
        let processActive: Bool?
        let processHidden: Bool?
        let processTerminated: Bool?
        let activationPolicy: String
        let ordinaryWindowCount: Int?
        let onscreenWindowCount: Int?

        var hasVisibleWindow: Bool? {
            onscreenWindowCount.map { $0 > 0 }
        }

        var isUserVisible: Bool? {
            guard let processActive,
                  let processHidden,
                  let processTerminated,
                  let onscreenWindowCount
            else { return nil }
            return processActive && !processHidden && !processTerminated && onscreenWindowCount > 0
        }
    }

    final class AppSwitcherSession {
        /// 返回值必须由调用方持有：DispatchSourceTimer 任务一旦释放，定时器就不会触发。
        typealias DelayScheduler = (UInt64, @escaping () -> Void) -> AnyObject?

        /// ⌥ 按下与 ⌘ 松开必须分两个事件周期送达：同一批送进 Dock 时，它处理 ⌘ 抬起
        /// 读到的已经是 ⌥ 松开的最终状态，最小化窗口不会回来。
        static let optionHoldMilliseconds: UInt64 = 60
        static let optionReleaseMilliseconds: UInt64 = 100
        static let windowPickerCommandReleaseMilliseconds: UInt64 = 80
        static let mainQueueScheduler: DelayScheduler = { milliseconds, action in
            let item = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Int(milliseconds)),
                execute: item
            )
            return item
        }

        private let keyStatePoster: KeyStatePoster
        private let scheduler: DelayScheduler
        private var diagnosticLogger: ((String) -> Void)?
        private var optionHoldTask: AnyObject?
        private var optionReleaseTask: AnyObject?
        private var commandReleaseTask: AnyObject?
        private(set) var isWindowPickerActive = false
        /// 窗口层里是否已经用方向键选中过某个窗口（原生语义：选中后 Enter/Esc 才响应）。
        private(set) var pickerHasHighlight = false
        private var commandReleasePending = false
        private(set) var isActive = false
        /// 已经按下 ⌥/保持 ⌘、但还没走完释放流程；调度失败时由 watchdog 兜底。
        private(set) var hasPendingRelease = false

        /// 合成按键按下与抬起之间保持的时长（微秒）。
        /// 真实按键会按住几十毫秒；按下抬起同一瞬间送达的合成事件，
        /// 部分系统 UI（macOS 13 的 App 切换器）会直接忽略。
        static let syntheticKeyHoldMicroseconds: UInt32 = 25_000

        /// ⌘ 按下与 Tab 按下之间要留出的间隔。
        ///
        /// 合成事件的修饰键状态不一定在下一条事件到达前就登记完：
        /// 真机日志（macOS 14/15）里“⌘ 刚按下就紧跟 Tab”经常打不开切换器，
        /// 而稍后再按一次（⌘ 已经按住）就能打开。
        static let commandSettleMicroseconds: UInt32 = 80_000

        /// 方向键是否真的能在切换器里移动高亮：nil 表示还没验证过。
        /// macOS 14/15 上方向键无效、Tab 循环有效（真机验证），因此验证失败
        /// 后就改用 Tab 循环。
        private(set) var arrowNavigationSupported: Bool?

        init(
            keyStatePoster: @escaping KeyStatePoster = KeyboardInjector.postKeyState,
            scheduler: @escaping DelayScheduler = AppSwitcherSession.mainQueueScheduler
        ) {
            self.keyStatePoster = keyStatePoster
            self.scheduler = scheduler
        }

        /// 记录方向键导航是否可用（由监视器在验证高亮后回填）。
        func markArrowNavigation(supported: Bool) {
            arrowNavigationSupported = supported
        }

        func setDiagnosticLogger(_ logger: @escaping (String) -> Void) {
            diagnosticLogger = logger
        }

        private func post(
            _ keyCode: CGKeyCode,
            isDown: Bool,
            flags: CGEventFlags,
            role: String
        ) -> Bool {
            let result = keyStatePoster(keyCode, isDown, flags)
            diagnosticLogger?(
                "role=\(role) key_code=\(keyCode) edge=\(isDown ? "down" : "up") " +
                    "command=\(flags.contains(.maskCommand)) success=\(result)"
            )
            return result
        }

        @discardableResult
        func trigger() -> Bool {
            if isActive {
                // 已经在窗口选择层，再发 ⌘Tab 会重开切换器。
                if isWindowPickerActive { return true }
                return postTab()
            }

            guard post(leftCommandKeyCode, isDown: true, flags: .maskCommand, role: "command") else {
                return false
            }
            // 等修饰键状态登记完再发 Tab，否则部分系统（macOS 14/15）会打不开切换器。
            usleep(Self.commandSettleMicroseconds)
            guard postTab() else {
                _ = post(leftCommandKeyCode, isDown: false, flags: [], role: "command")
                return false
            }
            isActive = true
            return true
        }

        @discardableResult
        func cancel() -> Bool {
            if isWindowPickerActive {
                _ = releaseCommandForWindowPicker()
                let escaped = post(53, isDown: true, flags: [], role: "escape") &&
                    post(53, isDown: false, flags: [], role: "escape")
                isWindowPickerActive = false
                isActive = false
                return escaped
            }
            guard isActive else { return true }
            let released = post(leftCommandKeyCode, isDown: false, flags: [], role: "command")
            isActive = false
            return released
        }

        /// 切换器里按 ↑/↓ 会进入目标 App 的窗口选择（App Exposé）：
        /// 第一次带 ⌘ 发送，让系统从切换器切到窗口层；之后 ⌘ 必须松开，
        /// 方向键和回车才能作用在窗口选择上，而不是变成 ⌘← / ⌘→ 之类的系统快捷键。
        @discardableResult
        func moveWindowSelection(up: Bool) -> Bool {
            guard isActive else { return false }
            if !isWindowPickerActive {
                // 原生只有 ⌘↓ 能进入窗口层；上键进入时同样发 ⌘↓，
                // 之后 ↑/↓ 只决定方向键的移动方向。
                let pressed = post(
                    125,
                    isDown: true,
                    flags: .maskCommand,
                    role: "window_picker"
                )
                usleep(Self.syntheticKeyHoldMicroseconds)
                let released = post(
                    125,
                    isDown: false,
                    flags: .maskCommand,
                    role: "window_picker"
                )
                isWindowPickerActive = true
                pickerHasHighlight = false
                commandReleasePending = true
                hasPendingRelease = true
                commandReleaseTask = scheduler(Self.windowPickerCommandReleaseMilliseconds) {
                    [weak self] in
                    _ = self?.releaseCommandForWindowPicker()
                }
                return pressed && released
            }
            let keyCode: CGKeyCode = up ? 126 : 125
            _ = releaseCommandForWindowPicker()
            let posted = post(keyCode, isDown: true, flags: [], role: "window_selection") &&
                post(keyCode, isDown: false, flags: [], role: "window_selection")
            if posted { pickerHasHighlight = true }
            return posted
        }

        @discardableResult
        private func releaseCommandForWindowPicker() -> Bool {
            guard commandReleasePending else { return true }
            commandReleasePending = false
            hasPendingRelease = false
            return post(leftCommandKeyCode, isDown: false, flags: [], role: "command")
        }

        /// 系统切换器只在「⌥ 已经按住、随后松开 ⌘」时才把目标 App 最小化的窗口带回前台。
        /// 先松开 ⌘ 再按 ⌥ 等价于普通 ⌘Tab，只会换成目标 App 的菜单栏，窗口仍留在程序坞。
        @discardableResult
        func confirm() -> Bool {
            guard isActive else { return true }
            if isWindowPickerActive {
                // 窗口选择层里 OK 等于回车：打开当前高亮的窗口。
                _ = releaseCommandForWindowPicker()
                let posted = postKeyWithHold(code: 36, flags: [], role: "return")
                isActive = false
                isWindowPickerActive = false
                return posted
            }
            isActive = false
            guard post(
                leftOptionKeyCode,
                isDown: true,
                flags: [.maskCommand, .maskAlternate],
                role: "option"
            ) else {
                return post(leftCommandKeyCode, isDown: false, flags: [], role: "command")
            }
            hasPendingRelease = true
            optionHoldTask = scheduler(Self.optionHoldMilliseconds) { [weak self] in
                guard let self else { return }
                _ = self.post(
                    KeyboardInjector.leftCommandKeyCode,
                    isDown: false,
                    flags: [.maskAlternate],
                    role: "command"
                )
                self.optionReleaseTask = self.scheduler(Self.optionReleaseMilliseconds) {
                    [weak self] in
                    guard let self else { return }
                    _ = self.post(
                        KeyboardInjector.leftOptionKeyCode,
                        isDown: false,
                        flags: [],
                        role: "option"
                    )
                    self.hasPendingRelease = false
                }
            }
            return true
        }

        /// 会话已经结束但系统切换器/窗口层还开着时，用它补一个 Escape。
        @discardableResult
        func dismissWindowPicker() -> Bool {
            isActive = false
            isWindowPickerActive = false
            commandReleasePending = false
            hasPendingRelease = false
            return post(53, isDown: true, flags: [], role: "escape") &&
                post(53, isDown: false, flags: [], role: "escape")
        }

        /// 调度器没有按期执行时的兜底：必须把 ⌘/⌥ 放开，不能把修饰键留在按下状态。
        @discardableResult
        func forceReleaseModifiersIfNeeded() -> Bool {
            guard hasPendingRelease else { return true }
            let commandReleased = post(
                leftCommandKeyCode,
                isDown: false,
                flags: [],
                role: "command"
            )
            let optionReleased = post(
                leftOptionKeyCode,
                isDown: false,
                flags: [],
                role: "option"
            )
            hasPendingRelease = false
            isWindowPickerActive = false
            commandReleasePending = false
            optionHoldTask = nil
            optionReleaseTask = nil
            return commandReleased && optionReleased
        }

        @discardableResult
        func moveSelection(left: Bool) -> Bool {
            guard isActive else { return false }
            if isWindowPickerActive {
                // 窗口层里 ⌘ 已经松开，方向键直接作用在窗口高亮上。
                _ = releaseCommandForWindowPicker()
                let posted = postKeyWithHold(
                    code: left ? 123 : 124,
                    flags: [],
                    role: "selection"
                )
                if posted { pickerHasHighlight = true }
                return posted
            }
            // 已经确认方向键无效的系统（macOS 14/15 真机验证）直接用 Tab 循环；
            // 还没验证过的先发方向键，由监视器核对高亮是否真的移动了。
            if arrowNavigationSupported == false {
                return cycleSelection(backwards: left)
            }
            return postKeyWithHold(
                code: left ? 123 : 124,
                flags: .maskCommand,
                role: "selection"
            )
        }

        /// 用 Tab（⌘Tab / ⌘⇧Tab）在切换器里循环高亮。
        @discardableResult
        func cycleSelection(backwards: Bool) -> Bool {
            guard isActive else { return false }
            let flags: CGEventFlags = backwards ? [.maskCommand, .maskShift] : .maskCommand
            return postKeyWithHold(code: 48, flags: flags, role: "cycle")
        }

        /// 按下与抬起之间保持一小段时间，模拟真实按键。
        private func postKeyWithHold(
            code: CGKeyCode,
            flags: CGEventFlags,
            role: String
        ) -> Bool {
            let pressed = post(code, isDown: true, flags: flags, role: role)
            usleep(Self.syntheticKeyHoldMicroseconds)
            let released = post(code, isDown: false, flags: flags, role: role)
            return pressed && released
        }

        private func postTab() -> Bool {
            postKeyWithHold(code: 48, flags: .maskCommand, role: "tab")
        }
    }

    struct AccessibilityTextCandidate: Equatable {
        let role: String
        let identifier: String
        let title: String
        let description: String
        let help: String
        let placeholder: String
        let context: String
        let frame: CGRect?
        let enabled: Bool
        let focused: Bool
        let selectedContext: Bool

        init(
            role: String,
            identifier: String,
            title: String,
            description: String,
            help: String,
            placeholder: String,
            context: String,
            frame: CGRect?,
            enabled: Bool,
            focused: Bool = false,
            selectedContext: Bool = false
        ) {
            self.role = role
            self.identifier = identifier
            self.title = title
            self.description = description
            self.help = help
            self.placeholder = placeholder
            self.context = context
            self.frame = frame
            self.enabled = enabled
            self.focused = focused
            self.selectedContext = selectedContext
        }
    }

    struct CmuxCommandResult: Equatable {
        let terminationStatus: Int32
        let standardOutput: Data
        let timedOut: Bool
    }

    static let syntheticEventMarker: Int64 = 0x5849_414F
    static let contextualMenuKeyCode: CGKeyCode = 110
    static let functionKeyCode: CGKeyCode = 63
    static let leftCommandKeyCode: CGKeyCode = 55
    static let rightCommandKeyCode: CGKeyCode = 54
    static let leftOptionKeyCode: CGKeyCode = 58
    /// Web content shells only build the accessibility tree once an assistive
    /// client announces itself, so the composer scan finds an empty shell until
    /// one of these attributes is set. `AXManualAccessibility` is the Chromium
    /// and Electron convention and is tried first, because the standard
    /// `AXEnhancedUserInterface` that VoiceOver uses is known to distort windows
    /// and animations on some Electron versions. Shells that are not Chromium
    /// based answer `attributeUnsupported` for the first attribute and only
    /// respond to the standard one, so it is used as a fallback for exactly
    /// those apps.
    static let manualAccessibilityAttribute = "AXManualAccessibility"
    static let enhancedUserInterfaceAttribute = "AXEnhancedUserInterface"
    /// The web content tree needs about one to two seconds after the attribute
    /// is set, so the composer scan keeps retrying for longer than that.
    static let composerFocusMaximumAttempts = 12
    static let composerFocusRetryMilliseconds = 250
    static let weChatBundleIdentifier = "com.tencent.xinWeChat"
    static let weChatComposerHorizontalRatio = 0.68
    static let weChatComposerVerticalRatio = 0.85
    /// One scroll action moves the conversation by this many lines; the 100ms
    /// repeat interval turns a held D-pad key into a steady scroll.
    static let scrollLineCount: Int32 = 3

    /// Page up / down scroll the recorded or preset region of the frontmost app.
    /// Never falls back to the window centre (decision S6).
    static let defaultScrollEdgePoster: (ScrollEdge) -> ScrollPageOutcome = { edge in
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let learned = ScrollRegionTargetStore.shared.target(for: bundleIdentifier)
        return ScrollRegionInjector.scrollToEdge(edge, learnedTarget: learned).outcome
    }

    static let defaultScrollPagePoster: (ScrollPageDirection) -> ScrollPageOutcome = { direction in
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let learned = ScrollRegionTargetStore.shared.target(for: bundleIdentifier)
        return ScrollRegionInjector.scrollPage(direction: direction, learnedTarget: learned).outcome
    }

    private static let focusRequests = ApplicationFocusRequestGate()
    private static let frontmostFocusRequests = ApplicationFocusRequestGate()
    private static let manualAccessibilityLock = NSLock()
    private static var manualAccessibilityLoggedProcesses: Set<pid_t> = []
    private static let focusQueue = DispatchQueue(
        label: "RemoteMic.application-focus",
        qos: .userInitiated
    )
    static let accessibilityChildAttributes = [
        "AXChildrenInNavigationOrder",
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXChildrenAttribute,
    ]
    static let maximumAccessibilityTraversalCount = 5_000

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestAccessibilityAccess() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func setFunctionKeyPressed(
        _ isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postKeyState
    ) -> Bool {
        setVoiceKeyPressed(
            .function,
            isPressed: isPressed,
            accessibilityTrusted: accessibilityTrusted,
            keyStatePoster: keyStatePoster
        )
    }

    @discardableResult
    static func setVoiceKeyPressed(
        _ mode: VoiceKeyMode,
        isPressed: Bool,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyStatePoster: KeyStatePoster = postKeyState
    ) -> Bool {
        guard accessibilityTrusted() else { return false }
        let flags = isPressed ? mode.eventFlags : []
        return keyStatePoster(
            mode.keyCode,
            isPressed,
            flags
        )
    }

    static func recordedShortcut(
        keyCode: UInt16, modifiers: [String], deviceModifierFlags: UInt64
    ) -> CustomKeyboardShortcut? {
        guard keyCode <= 127, deviceModifierFlags & ~UInt64(0x207f) == 0 else { return nil }
        var flags = NSEvent.ModifierFlags(rawValue: UInt(deviceModifierFlags))
        for modifier in modifiers {
            switch modifier {
            case "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option": flags.insert(.option)
            case "control": flags.insert(.control)
            case "function": flags.insert(.function)
            default: return nil
            }
        }
        return CustomKeyboardShortcut(keyCode: keyCode, modifierFlags: flags, keyLabel: "")
    }

    @discardableResult
    static func send(
        _ action: ButtonAction,
        shortcut: CustomKeyboardShortcut? = nil,
        applicationProfile: CustomApplicationProfile? = nil,
        applicationURL: (String) -> URL? = {
            if $0 == PresetApplication.remoteMic.bundleIdentifier {
                return Bundle.main.bundleURL
            }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        },
        applicationOpener: ApplicationOpener = openApplication,
        applicationFocuser: @escaping ApplicationFocuser = focusApplication,
        frontmostApplication: FrontmostApplicationProvider = {
            NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier ?? "", $0.processIdentifier) }
        },
        customApplicationURL: (CustomApplicationProfile) -> URL? = resolveCustomApplicationURL,
        customApplicationOpener: CustomApplicationOpener = openCustomApplication,
        customApplicationFocuser: @escaping CustomApplicationFocuser = focusCustomApplication,
        frontmostComposerFocuser: (@escaping (Bool) -> Void) -> Bool = focusFrontmostComposer,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        keyPoster: KeyPoster = { postKey(code: $0, flags: $1) },
        keyStatePoster: KeyStatePoster = postKeyState,
        scrollPoster: ScrollPoster = { postScrollWheel(lines: $0) },
        scrollPagePoster: (ScrollPageDirection) -> ScrollPageOutcome = defaultScrollPagePoster,
        scrollEdgePoster: (ScrollEdge) -> ScrollPageOutcome = defaultScrollEdgePoster,
        systemKeyPoster: SystemKeyPoster = postSystemKey,
        shortcutEventPoster: (CGEvent) -> Bool = ShortcutEventSequence.post,
        shortcutHardwareFlags: () -> CGEventFlags = { CGEventSource.flagsState(.hidSystemState) },
        logger: (String) -> Void = { AppLogger.shared.write($0) }
    ) -> Bool {
        guard action != .disabled else { return true }
        if action.isAppInternal {
            AppLogger.shared.write("INTERNAL ACTION ignored_by_keyboard action=\(action.rawValue)")
            return true
        }
        if let application = action.presetApplication {
            let focusRequestID = focusRequests.begin()
            open(
                application,
                focusRequestID: focusRequestID,
                applicationURL: applicationURL,
                applicationOpener: applicationOpener,
                applicationFocuser: applicationFocuser,
                frontmostApplication: frontmostApplication
            )
            return true
        }
        if action == .openCustomApplication {
            guard let applicationProfile else {
                AppLogger.shared.write("APP ACTION custom unavailable reason=profile_missing")
                return true
            }
            let focusRequestID = focusRequests.begin()
            open(
                applicationProfile,
                focusRequestID: focusRequestID,
                applicationURL: customApplicationURL,
                applicationOpener: customApplicationOpener,
                applicationFocuser: customApplicationFocuser,
                frontmostApplication: frontmostApplication
            )
            return true
        }
        if action == .focusInput {
            guard accessibilityTrusted() else { return false }
            return frontmostComposerFocuser { _ in }
        }
        if action == .customShortcut, shortcut == nil {
            AppLogger.shared.write("SHORTCUT ACTION ignored reason=not_configured")
            return true
        }
        if action == .customShortcut, let shortcut, let modifier = shortcut.standaloneModifier {
            let prefix = "SHORTCUT ACTION operation_id=\(UUID().uuidString)"
            let started = ProcessInfo.processInfo.systemUptime
            logger("\(prefix) phase=requested standalone=true")
            guard accessibilityTrusted() else {
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                logger(
                    "\(prefix) phase=completed result=rejected reason=accessibility_denied " +
                        "standalone=true elapsed_ms=\(elapsed) user_visible_result=unknown"
                )
                return false
            }

            let eventFlags = shortcut.cgEventFlags.union(modifier.deviceFlag)
            let pressed = keyStatePoster(CGKeyCode(shortcut.keyCode), true, eventFlags)
            // Even a failed press may have reached the system; always attempt its release.
            let released = keyStatePoster(CGKeyCode(shortcut.keyCode), false, [])
            let submitted = pressed && released
            let result = submitted ? "submitted" : "failed"
            let reason = !pressed ? "press_not_submitted" : !released ? "release_not_submitted" : "none"
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            logger(
                "\(prefix) phase=completed result=\(result) reason=\(reason) standalone=true " +
                    "press_submitted=\(pressed) release_submitted=\(released) " +
                    "elapsed_ms=\(elapsed) user_visible_result=unknown"
            )
            return submitted
        }
        guard accessibilityTrusted() else { return false }

        switch action {
        case .disabled:
            return true
        case .escape:
            keyPoster(53, [])
        case .returnKey:
            keyPoster(36, [])
        case .commandReturn:
            keyPoster(36, .maskCommand)
        case .shiftReturn:
            keyPoster(36, .maskShift)
        case .commandCopy:
            keyPoster(8, .maskCommand)
        case .commandPaste:
            keyPoster(9, .maskCommand)
        case .commandClose:
            keyPoster(13, .maskCommand)
        case .commandQuit:
            keyPoster(12, .maskCommand)
        case .commandCut:
            keyPoster(7, .maskCommand)
        case .commandSelectAll:
            keyPoster(0, .maskCommand)
        case .commandUndo:
            keyPoster(6, .maskCommand)
        case .commandRedo:
            keyPoster(6, [.maskCommand, .maskShift])
        case .commandFind:
            keyPoster(3, .maskCommand)
        case .commandSave:
            keyPoster(1, .maskCommand)
        case .commandDelete:
            keyPoster(51, .maskCommand)
        case .commandMinimize:
            keyPoster(46, .maskCommand)
        case .toggleFullScreen:
            keyPoster(3, [.maskControl, .maskCommand])
        case .commandNewTab:
            keyPoster(17, .maskCommand)
        case .commandPreviousTab:
            keyPoster(33, [.maskShift, .maskCommand])
        case .commandNextTab:
            keyPoster(30, [.maskShift, .maskCommand])
        case .commandNextWindow:
            keyPoster(50, .maskCommand)
        case .commandHide:
            keyPoster(4, .maskCommand)
        case .commandNew:
            keyPoster(45, .maskCommand)
        case .arrowUp:
            keyPoster(126, [])
        case .arrowDown:
            keyPoster(125, [])
        case .arrowLeft:
            keyPoster(123, [])
        case .arrowRight:
            keyPoster(124, [])
        case .scrollUp:
            scrollPoster(scrollLineCount)
        case .scrollDown:
            scrollPoster(-scrollLineCount)
        case .pageUp:
            return scrollPagePoster(.up).wasHandled
        case .pageDown:
            return scrollPagePoster(.down).wasHandled
        case .scrollToTop:
            return scrollEdgePoster(.top).wasHandled
        case .scrollToBottom:
            return scrollEdgePoster(.bottom).wasHandled
        case .deleteBackward:
            keyPoster(51, [])
        case .showDesktop:
            keyPoster(103, .maskSecondaryFn)
        case .contextMenu:
            keyPoster(contextualMenuKeyCode, [])
        case .appSwitcher:
            keyPoster(48, .maskCommand)
        case .missionControl:
            return postSymbolicHotKey(
                126,
                modifiers: [controlModifier],
                keyFlags: [.maskSecondaryFn, .maskNumericPad],
                keyStatePoster: keyStatePoster
            )
        case .applicationWindows:
            return postSymbolicHotKey(
                125,
                modifiers: [controlModifier],
                keyFlags: [.maskSecondaryFn, .maskNumericPad],
                keyStatePoster: keyStatePoster
            )
        case .spaceLeft:
            return postSymbolicHotKey(
                123,
                modifiers: [controlModifier],
                keyFlags: [.maskSecondaryFn, .maskNumericPad],
                keyStatePoster: keyStatePoster
            )
        case .spaceRight:
            return postSymbolicHotKey(
                124,
                modifiers: [controlModifier],
                keyFlags: [.maskSecondaryFn, .maskNumericPad],
                keyStatePoster: keyStatePoster
            )
        case .lockScreen:
            // ⌃⌘Q：真实按键顺序是先 Control 再 Command，收尾逆序抬起。
            return postSymbolicHotKey(
                12,
                modifiers: [controlModifier, commandModifier],
                keyStatePoster: keyStatePoster
            )
        case .screenshot:
            // ⌘⇧3：系统截屏快捷键，需要系统侧该项处于启用状态。
            return postSymbolicHotKey(
                20,
                modifiers: [commandModifier, shiftModifier],
                keyStatePoster: keyStatePoster
            )
        case .volumeUp:
            postSystemKey(type: 0)
        case .volumeDown:
            postSystemKey(type: 1)
        case .volumeMute:
            postSystemKey(type: 7)
        case .playPause:
            systemKeyPoster(16)
        case .previousCommandLeft:
            systemKeyPoster(18)
        case .nextCommandRight:
            systemKeyPoster(17)
        case .combinationAction:
            return false // The host action-library adapter owns execution.
        case .customShortcut:
            if let shortcut {
                let eventFlags = shortcut.cgEventFlags
                return ShortcutEventSequence.send(
                    keyCode: CGKeyCode(shortcut.keyCode),
                    modifiers: eventFlags,
                    hardwareFlags: shortcutHardwareFlags,
                    eventPoster: shortcutEventPoster
                )
            }
        case .focusInput:
            break
        case .openCustomApplication:
            break
        case .toggleLongRecording, .openCommonPhrases:
            break
        case .openRemoteMic, .openCodex, .openWorkBuddy, .openClaude, .openCmux, .openWeChat, .openCursor, .openXcode,
             .openSlack, .openWeCom, .openNeteaseMusic, .openChrome, .openSafari, .openZed, .openDimAgent:
            break
        }
        return true
    }

    private static func open(
        _ application: PresetApplication,
        focusRequestID: UInt64,
        applicationURL: (String) -> URL?,
        applicationOpener: ApplicationOpener,
        applicationFocuser: @escaping ApplicationFocuser,
        frontmostApplication: FrontmostApplicationProvider
    ) {
        guard let url = applicationURL(application.bundleIdentifier) else {
            AppLogger.shared.write("APP ACTION unavailable bundle=\(application.bundleIdentifier)")
            return
        }
        // Re-activating an app that is already frontmost makes its window go
        // through a resign/become-key cycle, which clears the web composer's
        // focus for about two seconds. The focuser below reaches the running
        // instance directly, so the activation step is skipped instead.
        if let frontmost = frontmostApplication(), frontmost.bundleIdentifier == application.bundleIdentifier {
            AppLogger.shared.write("APP ACTION skipped bundle=\(application.bundleIdentifier) reason=already_frontmost")
            if application.focusStrategy != nil {
                applicationFocuser(url, application, frontmost.processIdentifier, focusRequestID)
            }
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) " +
                        AppLogger.errorFields(error)
                )
            } else {
                AppLogger.shared.write("APP ACTION opened bundle=\(application.bundleIdentifier)")
                if application.focusStrategy != nil, let processIdentifier {
                    applicationFocuser(url, application, processIdentifier, focusRequestID)
                }
            }
        }
    }

    private static func openApplication(
        at url: URL,
        application: PresetApplication,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    private static func open(
        _ application: CustomApplicationProfile,
        focusRequestID: UInt64,
        applicationURL: (CustomApplicationProfile) -> URL?,
        applicationOpener: CustomApplicationOpener,
        applicationFocuser: @escaping CustomApplicationFocuser,
        frontmostApplication: FrontmostApplicationProvider
    ) {
        guard let url = applicationURL(application) else {
            AppLogger.shared.write(
                "APP ACTION unavailable bundle=\(application.bundleIdentifier) custom=true"
            )
            return
        }
        // Same as the preset path: re-activating an already frontmost app
        // clears the web composer's focus for about two seconds.
        if let frontmost = frontmostApplication(), frontmost.bundleIdentifier == application.bundleIdentifier {
            AppLogger.shared.write(
                "APP ACTION skipped bundle=\(application.bundleIdentifier) reason=already_frontmost custom=true"
            )
            guard application.focusStrategy != .none else { return }
            applicationFocuser(application, frontmost.processIdentifier, focusRequestID)
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) custom=true " +
                        AppLogger.errorFields(error)
                )
                return
            }
            AppLogger.shared.write(
                "APP ACTION opened bundle=\(application.bundleIdentifier) custom=true"
            )
            guard application.focusStrategy != .none, let processIdentifier else { return }
            applicationFocuser(application, processIdentifier, focusRequestID)
        }
    }

    private static func resolveCustomApplicationURL(
        _ application: CustomApplicationProfile
    ) -> URL? {
        let savedURL = URL(fileURLWithPath: application.applicationPath)
        if Bundle(url: savedURL)?.bundleIdentifier == application.bundleIdentifier {
            return savedURL
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        )
    }

    private static func openCustomApplication(
        at url: URL,
        application: CustomApplicationProfile,
        completion: @escaping (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    private static func focusCustomApplication(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        scheduleCustomApplicationFocus(
            application: application,
            processIdentifier: processIdentifier,
            requestID: requestID,
            attempt: 0
        )
    }

    private static func scheduleCustomApplicationFocus(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int
    ) {
        let maximumAttempts = 8
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(0) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard focusRequests.isCurrent(requestID) else { return }
            if isAccessibilityTrusted, application.focusStrategy == .recordedAccessibility {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier) {
                guard isAccessibilityTrusted else {
                    AppLogger.shared.write(
                        "APP FOCUS skipped bundle=\(application.bundleIdentifier) " +
                            "method=custom reason=not_trusted"
                    )
                    return
                }
                switch application.focusStrategy {
                case .none:
                    return
                case .keyboardShortcut:
                    if let shortcut = application.focusShortcut {
                        postKey(code: CGKeyCode(shortcut.keyCode), flags: shortcut.cgEventFlags)
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_shortcut"
                        )
                        return
                    }
                case .recordedAccessibility:
                    if let target = application.accessibilityTarget,
                       focusRecordedAccessibilityTarget(
                           target,
                           processIdentifier: processIdentifier
                       )
                    {
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_accessibility"
                        )
                        return
                    }
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < maximumAttempts {
                scheduleCustomApplicationFocus(
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt
                )
            } else if focusRequests.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) " +
                        "method=custom reason=target_not_focused"
                )
            }
        }
    }

    private static func focusApplication(
        at applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        guard focusRequests.isCurrent(requestID), let strategy = application.focusStrategy else { return }

        switch strategy {
        case .accessibilityComposer:
            scheduleAccessibilityComposerFocus(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: processIdentifier,
                requestID: requestID,
                requestGate: focusRequests,
                attempt: 0
            )
        case .cmuxSurfaceAPI:
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: application,
                processIdentifier: processIdentifier,
                requestID: requestID,
                attempt: 0
            )
        }
    }

    static func testCustomApplicationInput(_ profile: CustomApplicationProfile, completion: @escaping (Bool) -> Void) {
        guard isAccessibilityTrusted, let target = profile.accessibilityTarget,
            let url = resolveCustomApplicationURL(profile) else { completion(false); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            guard error == nil, let application else { completion(false); return }
            focusQueue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                let success = focusRecordedAccessibilityTarget(target, processIdentifier: application.processIdentifier)
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    @discardableResult
    static func focusFrontmostComposer(completion: @escaping (Bool) -> Void) -> Bool {
        focusFrontmostComposer(requestGate: frontmostFocusRequests,
                              requestID: frontmostFocusRequests.begin(), completion: completion)
    }

    static func focusFrontmostComposerForMacro() async throws -> Bool {
        let operationID = UUID().uuidString
        let startedAt = ContinuousClock.now
        AppLogger.shared.write("MACRO FOCUS operation_id=\(operationID) phase=started result=requested")
        do {
            let focused = try await ComposerFocusRequest.perform { gate, requestID, completion in
                focusFrontmostComposer(requestGate: gate, requestID: requestID, completion: completion)
            }
            let elapsed = startedAt.duration(to: .now).components
            let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
            AppLogger.shared.write("MACRO FOCUS operation_id=\(operationID) phase=completed result=\(focused ? "focused" : "not_focused") elapsed_ms=\(milliseconds)")
            return focused
        } catch {
            let reason = error is CancellationError ? "cancelled" : "timed_out"
            AppLogger.shared.write("MACRO FOCUS operation_id=\(operationID) phase=completed result=\(reason)")
            throw error
        }
    }

    static func focusFrontmostComposer(
        requestGate: ApplicationFocusRequestGate,
        requestID: UInt64,
        accessibilityTrusted: () -> Bool = { isAccessibilityTrusted },
        frontmostApplication: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard requestGate.isCurrent(requestID) else { return false }
        guard accessibilityTrusted(),
              let application = frontmostApplication()
        else { return false }
        // In-process AX queries can enter SwiftUI off-main and deadlock its view graph.
        if application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            AppLogger.shared.write(
                "APP FOCUS operation_id=\(requestID) phase=completed result=skipped reason=self_frontmost"
            )
            completeComposerFocus(false, requestID: requestID, requestGate: requestGate, completion: completion)
            return true
        }
        if application.bundleIdentifier == PresetApplication.cmux.bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: PresetApplication.cmux.bundleIdentifier
           ) {
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: .cmux,
                processIdentifier: application.processIdentifier,
                requestID: requestID,
                attempt: 0,
                requestGate: requestGate,
                completion: completion
            )
            return true
        }
        scheduleAccessibilityComposerFocus(
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            processIdentifier: application.processIdentifier,
            requestID: requestID,
            requestGate: requestGate,
            attempt: 0,
            completion: completion
        )
        return true
    }

    private static func scheduleCmuxFocus(
        applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int,
        requestGate: ApplicationFocusRequestGate = focusRequests,
        completion: ((Bool) -> Void)? = nil
    ) {
        let maximumAttempts = 4
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(100) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }
            let nextAttempt = attempt + 1
            if !applicationIsFrontmost(processIdentifier) {
                if nextAttempt < maximumAttempts {
                    scheduleCmuxFocus(
                        applicationURL: applicationURL,
                        application: application,
                        processIdentifier: processIdentifier,
                        requestID: requestID,
                        attempt: nextAttempt,
                        requestGate: requestGate,
                        completion: completion
                    )
                } else {
                    completeComposerFocus(
                        false,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                }
                return
            }
            let canContinue = {
                requestGate.isCurrent(requestID) && applicationIsFrontmost(processIdentifier)
            }
            let focused = focusCmux(
                applicationURL: applicationURL,
                canContinue: canContinue,
                terminalFocuser: { _ in
                    guard isAccessibilityTrusted else {
                        AppLogger.shared.write(
                            "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=not_trusted"
                        )
                        return false
                    }
                    return focusCmuxTerminal(
                        processIdentifier: processIdentifier,
                        keyPoster: { postKey(code: $0, flags: $1) }
                    )
                }
            )
            if focused {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(application.bundleIdentifier) method=cmux_api_accessibility"
                )
                completeComposerFocus(
                    true,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }

            if nextAttempt < maximumAttempts {
                scheduleCmuxFocus(
                    applicationURL: applicationURL,
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt,
                    requestGate: requestGate,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=terminal_not_focused"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func scheduleAccessibilityComposerFocus(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        attempt: Int,
        completion: ((Bool) -> Void)? = nil
    ) {
        let delay: DispatchTimeInterval = attempt == 0
            ? .milliseconds(0)
            : .milliseconds(composerFocusRetryMilliseconds)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }

            if applicationIsFrontmost(processIdentifier), !isAccessibilityTrusted {
                AppLogger.shared.write(
                    "APP FOCUS skipped bundle=\(bundleIdentifier) method=accessibility reason=not_trusted"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }
            if attempt == 0,
               usesWeChatComposerFallback(bundleIdentifier: bundleIdentifier),
               applicationIsFrontmost(processIdentifier),
               focusWeChatComposer(processIdentifier: processIdentifier) {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(bundleIdentifier) method=wechat_window_click"
                )
                completeComposerFocus(
                    true,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }
            if isAccessibilityTrusted {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier), isAccessibilityTrusted {
                // 内置记录优先：它代表真机上验证过的输入框，命中后就是用户学习过的结果；
                // 记录对不上（窗口结构变化）时继续走下面的启发式扫描，不阻断原有路径。
                if let presetTarget = AccessibilityFocusPreset.target(for: bundleIdentifier),
                   focusRecordedAccessibilityTarget(presetTarget, processIdentifier: processIdentifier) {
                    AppLogger.shared.write(
                        "APP FOCUS succeeded bundle=\(bundleIdentifier) method=preset_recorded"
                    )
                    completeComposerFocus(
                        true,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                    return
                }
                if focusComposer(
                    processIdentifier: processIdentifier,
                    emitDiagnostics: attempt == 0 || attempt + 1 == composerFocusMaximumAttempts
                ) {
                    AppLogger.shared.write(
                        "APP FOCUS succeeded bundle=\(bundleIdentifier) method=accessibility"
                    )
                    completeComposerFocus(
                        true,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                    return
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < composerFocusMaximumAttempts {
                scheduleAccessibilityComposerFocus(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    requestGate: requestGate,
                    attempt: nextAttempt,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(bundleIdentifier) method=accessibility reason=composer_not_found"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func completeComposerFocus(
        _ focused: Bool,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        completion: ((Bool) -> Void)?
    ) {
        guard let completion else { return }
        if Thread.isMainThread {
            guard requestGate.isCurrent(requestID) else { return }
            completion(focused)
            return
        }
        DispatchQueue.main.async {
            guard requestGate.isCurrent(requestID) else { return }
            completion(focused)
        }
    }

    static func manualAccessibilityResultName(_ result: AXError) -> String {
        switch result {
        case .success: return "success"
        case .attributeUnsupported: return "attribute_unsupported"
        case .cannotComplete: return "cannot_complete"
        case .invalidUIElement: return "invalid_element"
        case .apiDisabled: return "api_disabled"
        case .notImplemented: return "not_implemented"
        default: return "error_\(result.rawValue)"
        }
    }

    /// The fallback only runs when the Chromium attribute is unsupported, so the
    /// log has to name which attribute actually answered.
    static func manualAccessibilityResultToken(primary: AXError, fallback: AXError?) -> String {
        guard let fallback else { return manualAccessibilityResultName(primary) }
        return "fallback_enhanced_\(manualAccessibilityResultName(fallback))"
    }

    /// The fallback answer wins whenever it was attempted, because the primary
    /// attribute was unsupported by that app.
    static func manualAccessibilityEffectiveResult(
        primary: AXError,
        fallback: AXError?
    ) -> AXError {
        if primary == .success { return .success }
        return fallback ?? primary
    }

    /// The attribute is set on every attempt because it is idempotent, but only
    /// the first attempt and the attempt that finally builds the tree carry new
    /// information; the retries in between would repeat the same reason.
    static func shouldLogManualAccessibility(
        result: AXError,
        attempt: Int,
        alreadyLoggedSuccess: Bool
    ) -> Bool {
        if attempt == 0 { return true }
        return result == .success && !alreadyLoggedSuccess
    }

    @discardableResult
    private static func announceManualAccessibility(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        attempt: Int
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let primary = AXUIElementSetAttributeValue(
            applicationElement,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        var fallback: AXError?
        if primary == .attributeUnsupported {
            fallback = AXUIElementSetAttributeValue(
                applicationElement,
                enhancedUserInterfaceAttribute as CFString,
                kCFBooleanTrue
            )
        }
        let result = manualAccessibilityEffectiveResult(primary: primary, fallback: fallback)

        manualAccessibilityLock.lock()
        let alreadyLoggedSuccess = manualAccessibilityLoggedProcesses.contains(processIdentifier)
        let shouldLog = shouldLogManualAccessibility(
            result: result,
            attempt: attempt,
            alreadyLoggedSuccess: alreadyLoggedSuccess
        )
        if result == .success {
            if manualAccessibilityLoggedProcesses.count >= 64 {
                manualAccessibilityLoggedProcesses.removeAll()
            }
            manualAccessibilityLoggedProcesses.insert(processIdentifier)
        }
        manualAccessibilityLock.unlock()

        if shouldLog {
            AppLogger.shared.write(
                "APP FOCUS manual_accessibility bundle=\(bundleIdentifier) " +
                    "attempt=\(attempt) " +
                    "result=\(manualAccessibilityResultToken(primary: primary, fallback: fallback))"
            )
        }
        return result == .success
    }

    private static func applicationIsFrontmost(_ processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    private static func focusComposer(
        processIdentifier: pid_t,
        emitDiagnostics: Bool = false
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var windowCount = 0
        var candidateCount = 0
        var eligibleCount = 0
        var excludedSensitiveCount = 0
        for window in applicationWindows(applicationElement) {
            windowCount += 1
            let candidates = accessibilityTextCandidates(in: window)
            candidateCount += candidates.count
            for candidate in candidates.map(\.snapshot) {
                let semanticText = [
                    candidate.identifier,
                    candidate.title,
                    candidate.description,
                    candidate.help,
                    candidate.placeholder,
                    candidate.context,
                ].joined(separator: " ").lowercased()
                if composerCandidateScore(candidate, windowFrame: axFrame(window)) != nil {
                    eligibleCount += 1
                } else if containsSensitiveAccessibilityTerms(semanticText) {
                    excludedSensitiveCount += 1
                }
            }
            guard let candidateIndex = bestComposerCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            if focusAccessibilityElement(
                candidates[candidateIndex].element,
                applicationElement: applicationElement
            ) {
                return true
            }
        }
        if emitDiagnostics {
            AppLogger.shared.write(
                "APP FOCUS scan bundle=\(NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier ?? "unknown") " +
                    "windows=\(windowCount) candidates=\(candidateCount) eligible=\(eligibleCount) " +
                    "excluded_sensitive=\(excludedSensitiveCount)"
            )
        }
        return false
    }

    static func weChatComposerFocusPoint(windowFrame: CGRect) -> CGPoint? {
        guard windowFrame.width >= 700, windowFrame.height >= 500 else { return nil }
        return CGPoint(
            x: windowFrame.minX + windowFrame.width * weChatComposerHorizontalRatio,
            y: windowFrame.minY + windowFrame.height * weChatComposerVerticalRatio
        )
    }

    static func usesWeChatComposerFallback(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == weChatBundleIdentifier
    }

    static func prepareCommonPhraseUnavailableTarget(processIdentifier: pid_t) -> Bool {
        // 本回退是微信专用：其他 App 的 AX 校验仍然照常把守（敏感输入框、
        // 前台变化等拒绝语义不受影响）。
        guard usesWeChatComposerFallback(
            bundleIdentifier: NSRunningApplication(
                processIdentifier: processIdentifier
            )?.bundleIdentifier
        ) else { return false }
        // 微信只有输入框聚焦后才通过 AX 暴露焦点元素（打字后可读，仅点击聚焦
        // 时不可读），所以这里的 noValue 不能作为“光标不在输入框”的判据。
        // 合成点击无法可靠聚焦微信输入框（点击后 AX 焦点不发布、落点可能命
        // 中会话列表），而粘贴本身是安全的：⌘V 不导航、不破坏内容，聚焦时
        // 精确落在光标/选区，未聚焦时静默无操作。选区保护由私有包在插入前
        // 不再写 AX 焦点来保证。这里直接放行粘贴。
        return true
    }

    static func weChatComposerWindowFrame(
        _ windows: [(title: String, frame: CGRect)]
    ) -> CGRect? {
        windows
            .filter {
                ($0.title == "微信" || $0.title == "WeChat") &&
                    weChatComposerFocusPoint(windowFrame: $0.frame) != nil
            }
            .map(\.frame)
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func focusWeChatComposer(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let frame = weChatComposerWindowFrame(
            applicationWindows(applicationElement).compactMap { window in
                guard let frame = axFrame(window) else { return nil }
                return (
                    title: axString(window, attribute: kAXTitleAttribute),
                    frame: frame
                )
            }
        ),
              let point = weChatComposerFocusPoint(windowFrame: frame),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              )
        else { return false }
        let previousPointerLocation = CGEvent(source: nil)?.location
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        if let previousPointerLocation,
           let restore = CGEvent(
               mouseEventSource: source,
               mouseType: .mouseMoved,
               mouseCursorPosition: previousPointerLocation,
               mouseButton: .left
           ) {
            restore.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            restore.post(tap: .cghidEventTap)
        }
        return true
    }

    static func captureFocusedAccessibilityTarget(
        bundleIdentifier: String
    ) -> AccessibilityFocusTarget? {
        guard isAccessibilityTrusted else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier == bundleIdentifier
        else { return nil }

        let role = axString(focusedElement, attribute: kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField",
              axBool(focusedElement, attribute: kAXEnabledAttribute) ?? true
        else { return nil }

        var contextParts: [String] = []
        var current = axElement(focusedElement, attribute: kAXParentAttribute)
        var window = axElement(focusedElement, attribute: kAXWindowAttribute)
        var ancestorCount = 0
        while let element = current, ancestorCount < 8 {
            let semanticText = axSemanticText(element)
            if !semanticText.isEmpty {
                contextParts.append(semanticText)
            }
            if axString(element, attribute: kAXRoleAttribute) == "AXWindow" {
                window = window ?? element
                break
            }
            current = axElement(element, attribute: kAXParentAttribute)
            ancestorCount += 1
        }

        let context = recordedAccessibilityContext(ancestorParts: contextParts,
            windowSemanticText: window.map(axSemanticText) ?? "")
        let target = AccessibilityFocusTarget(
            role: role,
            identifier: axString(focusedElement, attribute: kAXIdentifierAttribute),
            title: axString(focusedElement, attribute: kAXTitleAttribute),
            description: axString(focusedElement, attribute: kAXDescriptionAttribute),
            help: axString(focusedElement, attribute: kAXHelpAttribute),
            placeholder: axString(focusedElement, attribute: kAXPlaceholderValueAttribute),
            context: context,
            windowTitle: window.map { axString($0, attribute: kAXTitleAttribute) } ?? "",
            normalizedFrame: normalizedAccessibilityFrame(
                elementFrame: axFrame(focusedElement),
                windowFrame: window.flatMap(axFrame)
            )
        )
        let semanticText = [
            target.identifier,
            target.title,
            target.description,
            target.help,
            target.placeholder,
            target.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText),
              !semanticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return target
    }

    static func recordedAccessibilityContext(ancestorParts: [String], windowSemanticText: String) -> String {
        let context = ancestorParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // Deep anonymous editors may reach the ancestor limit before their window.
        return String((context.isEmpty ? windowSemanticText : context).suffix(512))
    }

    private static func focusRecordedAccessibilityTarget(
        _ target: AccessibilityFocusTarget,
        processIdentifier: pid_t
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var ranked: [(element: AXUIElement, score: Int)] = []
        for window in applicationWindows(applicationElement) {
            let windowFrame = axFrame(window)
            let windowTitle = axString(window, attribute: kAXTitleAttribute)
            for candidate in accessibilityTextCandidates(in: window) {
                guard let score = recordedAccessibilityCandidateScore(
                    candidate.snapshot,
                    target: target,
                    windowTitle: windowTitle,
                    windowFrame: windowFrame
                ) else { continue }
                ranked.append((candidate.element, score))
            }
        }
        ranked.sort { $0.score > $1.score }
        guard let best = ranked.first,
              ranked.dropFirst().first.map({ best.score - $0.score >= 40 }) ?? true
        else { return false }
        return focusAccessibilityElement(
            best.element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: true
        )
    }

    static func recordedAccessibilityCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        target: AccessibilityFocusTarget,
        windowTitle: String,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == target.role else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText) else { return nil }

        var score = 0
        var strongMatches = 0
        if semanticValuesMatch(candidate.identifier, target.identifier) {
            score += 500
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.placeholder, target.placeholder) {
            score += 220
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.title, target.title) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.description, target.description) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.help, target.help) {
            score += 100
            strongMatches += 1
        }
        if semanticValuesMatch(windowTitle, target.windowTitle) {
            score += 100
        }

        let contextSimilarity = accessibilityContextSimilarity(candidate.context, target.context)
        score += Int(contextSimilarity * 180)
        if contextSimilarity >= 0.5 {
            strongMatches += 1
        }

        if let targetFrame = target.normalizedFrame,
           let candidateFrame = normalizedAccessibilityFrame(
               elementFrame: candidate.frame,
               windowFrame: windowFrame
           )
        {
            let distance = abs(targetFrame.x - candidateFrame.x) +
                abs(targetFrame.y - candidateFrame.y) +
                abs(targetFrame.width - candidateFrame.width) +
                abs(targetFrame.height - candidateFrame.height)
            score += max(0, 120 - Int(distance * 120))
        }

        guard strongMatches > 0 else { return nil }
        return score >= 180 ? score : nil
    }

    private static func normalizedAccessibilityFrame(
        elementFrame: CGRect?,
        windowFrame: CGRect?
    ) -> NormalizedAccessibilityFrame? {
        guard let elementFrame, let windowFrame,
              windowFrame.width > 0, windowFrame.height > 0
        else { return nil }
        return NormalizedAccessibilityFrame(
            x: (elementFrame.minX - windowFrame.minX) / windowFrame.width,
            y: (elementFrame.minY - windowFrame.minY) / windowFrame.height,
            width: elementFrame.width / windowFrame.width,
            height: elementFrame.height / windowFrame.height
        )
    }

    private static func semanticValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return min(lhs.count, rhs.count) >= 4 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    private static func accessibilityContextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = accessibilityTokens(lhs)
        let right = accessibilityTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }

    private static func accessibilityTokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased().components(
                separatedBy: CharacterSet.alphanumerics.inverted
            ).filter { $0.count >= 2 }
        )
    }

    private static func containsSensitiveAccessibilityTerms(_ value: String) -> Bool {
        let value = value.lowercased()
        let terms = [
            "password", "passcode", "secret", "api key", "apikey", "token", "credit card",
            "密码", "口令", "密钥", "令牌", "银行卡",
        ]
        return terms.contains(where: value.contains)
    }

    private static func applicationWindows(_ applicationElement: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in [
            axElement(applicationElement, attribute: kAXFocusedWindowAttribute),
            axElement(applicationElement, attribute: kAXMainWindowAttribute),
        ].compactMap({ $0 }) + axElements(applicationElement, attribute: kAXWindowsAttribute) {
            if !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        return windows
    }

    private static func accessibilityTextCandidates(
        in window: AXUIElement
    ) -> [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] {
        struct PendingElement {
            let element: AXUIElement
            let context: String
            let selectedContext: Bool
        }

        let windowFrame = axFrame(window)
        var stack = [PendingElement(
            element: window,
            context: axSemanticText(window),
            selectedContext: axBool(window, attribute: kAXSelectedAttribute) ?? false
        )]
        var visitedElements: [CFHashCode: [AXUIElement]] = [CFHash(window): [window]]
        var visitedCount = 0
        var candidates: [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] = []

        while let current = stack.popLast(), visitedCount < maximumAccessibilityTraversalCount {
            visitedCount += 1
            let ownContext = axSemanticText(current.element)
            let combinedContext = [current.context, ownContext]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let role = axString(current.element, attribute: kAXRoleAttribute)
            let frame = axFrame(current.element)
            let selectedContext = current.selectedContext ||
                (axBool(current.element, attribute: kAXSelectedAttribute) ?? false)

            if role == "AXTextArea" || role == "AXTextField" {
                candidates.append((
                    current.element,
                    AccessibilityTextCandidate(
                        role: role,
                        identifier: axString(current.element, attribute: kAXIdentifierAttribute),
                        title: axString(current.element, attribute: kAXTitleAttribute),
                        description: axString(current.element, attribute: kAXDescriptionAttribute),
                        help: axString(current.element, attribute: kAXHelpAttribute),
                        placeholder: axString(current.element, attribute: kAXPlaceholderValueAttribute),
                        context: combinedContext,
                        frame: frame,
                        enabled: axBool(current.element, attribute: kAXEnabledAttribute) ?? true,
                        focused: axBool(current.element, attribute: kAXFocusedAttribute) ?? false,
                        selectedContext: selectedContext
                    )
                ))
            }

            let childContext = String(combinedContext.suffix(512))
            var children: [AXUIElement] = []
            for attribute in accessibilityChildAttributes {
                for child in axElements(current.element, attribute: attribute) {
                    let hash = CFHash(child)
                    if visitedElements[hash]?.contains(where: { CFEqual($0, child) }) == true {
                        continue
                    }
                    visitedElements[hash, default: []].append(child)
                    children.append(child)
                }
            }
            children.sort {
                accessibilityTraversalPriority(
                    role: axString($0, attribute: kAXRoleAttribute),
                    frame: axFrame($0),
                    windowFrame: windowFrame
                ) < accessibilityTraversalPriority(
                    role: axString($1, attribute: kAXRoleAttribute),
                    frame: axFrame($1),
                    windowFrame: windowFrame
                )
            }
            stack.append(contentsOf: children.map {
                PendingElement(element: $0, context: childContext, selectedContext: selectedContext)
            })
        }
        return candidates
    }

    static func accessibilityTraversalPriority(
        role: String,
        frame: CGRect?,
        windowFrame: CGRect?
    ) -> Int {
        var priority = role == "AXTextArea" || role == "AXTextField" ? 1_000_000 : 0
        guard let frame, let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else {
            return priority
        }
        if frame.intersects(windowFrame) {
            priority += 100_000
        }
        let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
        priority += Int(max(0, min(1, verticalPosition)) * 10_000)
        return priority
    }

    /// Fallback caret placement: the standard "end of document" key (Cmd+Down).
    /// Programmatic focus alone leaves the caret at offset 0 in Chromium hosts
    /// (WorkBuddy, Codex, Claude), and WorkBuddy-style editors report unreliable
    /// character counts that break out-of-range AXSelectedTextRange writes on
    /// empty composers, so the chord is used instead of selection writes. It is
    /// a no-op on an empty composer and reaches the end on non-empty content.
    static let composerCaretEndKey: (keyCode: CGKeyCode, flags: CGEventFlags) = (125, [.maskCommand])
    private static let composerCommandKeyCode: CGKeyCode = 55

    /// Posts the chord exactly like a real keyboard: Command press, arrow
    /// down/up, then Command release. Without the trailing Command release the
    /// system modifier state would keep Command held after the action, which
    /// poisons every later key event in the session.
    private static func postComposerCaretEndKey() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        func post(_ event: CGEvent?) {
            guard let event else { return }
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
        if let commandPress = CGEvent(keyboardEventSource: source, virtualKey: composerCommandKeyCode, keyDown: false) {
            commandPress.flags = composerCaretEndKey.flags
            post(commandPress)
        }
        post(CGEvent(keyboardEventSource: source, virtualKey: composerCaretEndKey.keyCode, keyDown: true))
        if let arrowUp = CGEvent(keyboardEventSource: source, virtualKey: composerCaretEndKey.keyCode, keyDown: false) {
            arrowUp.flags = composerCaretEndKey.flags
            post(arrowUp)
        }
        if let commandRelease = CGEvent(keyboardEventSource: source, virtualKey: composerCommandKeyCode, keyDown: false) {
            commandRelease.flags = []
            post(commandRelease)
        }
    }

    private static func composerCaretProcessIdentifier(for element: AXUIElement) -> pid_t {
        var processIdentifier: pid_t = 0
        AXUIElementGetPid(element, &processIdentifier)
        return processIdentifier
    }

    private static func composerCaretBundleIdentifier(for element: AXUIElement) -> String {
        NSRunningApplication(processIdentifier: composerCaretProcessIdentifier(for: element))?
            .bundleIdentifier ?? "unknown"
    }

    private static func logComposerCaret(
        _ result: String,
        bundleIdentifier: String,
        element: AXUIElement
    ) {
        AppLogger.shared.write(
            "APP FOCUS caret bundle=\(bundleIdentifier) " +
                "role=\(axString(element, attribute: kAXRoleAttribute)) result=\(result)"
        )
    }

    /// Sends the end-of-document chord and logs it.
    private static func sendComposerCaretEndKey(for element: AXUIElement, bundleIdentifier: String) {
        postComposerCaretEndKey()
        logComposerCaret("end_key_sent", bundleIdentifier: bundleIdentifier, element: element)
    }

    /// Writes a remembered caret range back into the focused composer. Hosts
    /// clamp out-of-range values, which degrades to "end of the (shortened)
    /// text" — the documented fallback for content that shrank while unfocused.
    private static func restoreComposerCaretRange(
        _ range: CFRange,
        for element: AXUIElement,
        bundleIdentifier: String
    ) {
        var stored = range
        if let value = AXValueCreate(.cfRange, &stored) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
        }
        logComposerCaret("restored", bundleIdentifier: bundleIdentifier, element: element)
    }

    /// 已聚焦入口：光标就在用户手里，读取当前偏移记入记忆并保持跟踪，
    /// 不移动光标——这正是“恢复到之前的状态”要记住的状态。
    private static func rememberComposerCaret(element: AXUIElement, bundleIdentifier: String) {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else {
            logComposerCaret("remember_failed", bundleIdentifier: bundleIdentifier, element: element)
            return
        }
        var range = CFRange()
        AXValueGetValue(value as! AXValue, .cfRange, &range)
        ComposerCaretStore.shared.remember(range, forKey: bundleIdentifier)
        logComposerCaret("remembered", bundleIdentifier: bundleIdentifier, element: element)
    }

    private static func focusAccessibilityElement(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool = false,
        restoresComposerCaret: Bool = true
    ) -> Bool {
        let bundleIdentifier = composerCaretBundleIdentifier(for: element)
        if accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        ) {
            if restoresComposerCaret {
                rememberComposerCaret(element: element, bundleIdentifier: bundleIdentifier)
                ComposerCaretObserver.shared.beginObserving(
                    element: element,
                    processIdentifier: composerCaretProcessIdentifier(for: element),
                    key: bundleIdentifier
                )
            }
            return true
        }
        // 有记忆偏移时先预置选区再请求焦点：宿主把它缓存为该输入框的选区，
        // 聚焦在同一帧直接恢复到这个位置，不会先画出偏移 0 的光标。
        if restoresComposerCaret,
           let stored = ComposerCaretStore.shared.rememberedRange(forKey: bundleIdentifier) {
            restoreComposerCaretRange(stored, for: element, bundleIdentifier: bundleIdentifier)
        }
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        )
        // 没有记忆偏移时，末尾键立即发送（先于确认读，避免宿主先画出偏移 0
        // 的光标形成可见闪动）；确认后还会补发一次兜底。
        if restoresComposerCaret,
           ComposerCaretStore.shared.rememberedRange(forKey: bundleIdentifier) == nil {
            sendComposerCaretEndKey(for: element, bundleIdentifier: bundleIdentifier)
        }
        var focused = accessibilityElementIsFocused(
            element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
        if !focused {
            _ = AXUIElementPerformAction(element, kAXPressAction as CFString)
            focused = accessibilityElementIsFocused(
                element,
                applicationElement: applicationElement,
                requiresApplicationFocusedElement: requiresApplicationFocusedElement
            )
        }
        if focused, restoresComposerCaret {
            // 预置成功时这里重写记忆偏移是幂等无操作（AXPress 兜底路径则抵消
            // 按压落点）；没有记忆偏移时补发末尾键，覆盖首次末尾键先于聚焦
            // 生效而落空的情况。
            if let stored = ComposerCaretStore.shared.rememberedRange(forKey: bundleIdentifier) {
                restoreComposerCaretRange(stored, for: element, bundleIdentifier: bundleIdentifier)
            } else {
                sendComposerCaretEndKey(for: element, bundleIdentifier: bundleIdentifier)
            }
            ComposerCaretObserver.shared.beginObserving(
                element: element,
                processIdentifier: composerCaretProcessIdentifier(for: element),
                key: bundleIdentifier
            )
        }
        return focused
    }

    private static func accessibilityElementIsFocused(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        let applicationFocusedElementMatches = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { CFEqual($0, element) }
        return accessibilityFocusIsConfirmed(
            elementFocused: axBool(element, attribute: kAXFocusedAttribute) == true,
            applicationFocusedElementMatches: applicationFocusedElementMatches,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
    }

    static func accessibilityFocusIsConfirmed(
        elementFocused: Bool,
        applicationFocusedElementMatches: Bool?,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        if requiresApplicationFocusedElement {
            return applicationFocusedElementMatches == true
        }
        return elementFocused || applicationFocusedElementMatches == true
    }

    static func bestComposerCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = composerCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func composerCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == "AXTextArea" || candidate.role == "AXTextField" else {
            return nil
        }

        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()

        let excludedTerms = [
            "title", "rename", "api key", "apikey", "token", "password", "secret",
            "command palette", "address bar", "approval", "permission", "code editor", "monaco",
            "标题", "重命名", "密钥", "令牌", "密码", "审批", "权限", "代码编辑器",
        ]
        guard !excludedTerms.contains(where: semanticText.contains) else { return nil }

        let strongTerms = [
            "composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
            "message-input", "message_input", "prompt input", "message input",
            "消息输入", "输入消息", "发送消息",
        ]
        let supportingTerms = [
            "message", "prompt", "reply", "ask claude", "ask anything", "chat", "提问", "回复",
        ]
        let explicitlyAllowedTerms = [
            "search", "find", "filter", "settings", "preferences", "terminal", "console", "shell", "xterm",
            "搜索", "查找", "筛选", "设置", "偏好", "终端", "控制台",
        ]
        let hasStrongSemanticMatch = strongTerms.contains(where: semanticText.contains)
        let hasSupportingSemanticMatch = supportingTerms.contains(where: semanticText.contains)
        let hasExplicitlyAllowedMatch = explicitlyAllowedTerms.contains(where: semanticText.contains)
        guard candidate.role == "AXTextArea" || hasStrongSemanticMatch || hasSupportingSemanticMatch ||
                hasExplicitlyAllowedMatch else {
            return nil
        }

        var score = candidate.role == "AXTextArea" ? 50 : 0
        if hasStrongSemanticMatch {
            score += 120
        } else if hasSupportingSemanticMatch {
            score += 70
        } else if hasExplicitlyAllowedMatch {
            score += 80
        }

        if let frame = candidate.frame {
            if frame.width >= 280 { score += 25 }
            if (24...500).contains(frame.height) { score += 10 }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                if frame.width / windowFrame.width >= 0.45 { score += 30 }
                let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
                if verticalPosition >= 0.55 {
                    score += 20
                } else if verticalPosition <= 0.25 {
                    score -= 15
                }
            }
        }

        return score >= 80 ? score : nil
    }

    private static func focusCmuxTerminal(
        processIdentifier: pid_t,
        keyPoster: KeyPoster
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var terminalFrame: CGRect?
        for window in applicationWindows(applicationElement) {
            let candidates = accessibilityTextCandidates(in: window)
            guard let candidateIndex = bestCmuxTerminalCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            terminalFrame = terminalFrame ?? candidates[candidateIndex].snapshot.frame
            if focusAccessibilityElement(
                candidates[candidateIndex].element,
                applicationElement: applicationElement,
                requiresApplicationFocusedElement: true,
                restoresComposerCaret: false
            ) {
                return true
            }
        }

        let focusedElementSnapshot = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { focusedElement in
            (
                role: axString(focusedElement, attribute: kAXRoleAttribute),
                frame: axFrame(focusedElement)
            )
        }
        if let keyCode = cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: focusedElementSnapshot?.role,
            focusedFrame: focusedElementSnapshot?.frame,
            terminalFrame: terminalFrame
        ) {
            keyPoster(keyCode, [.maskCommand, .maskShift])
        }
        return false
    }

    static func cmuxFocusRecoveryShortcutKeyCode(
        focusedRole: String?,
        focusedFrame: CGRect?,
        terminalFrame: CGRect?
    ) -> CGKeyCode? {
        if let focusedFrame, let terminalFrame,
           focusedFrame.minX >= terminalFrame.maxX {
            return 14 // Cmd+Shift+E: cmux Toggle Right Sidebar Focus returns to the terminal.
        }
        switch focusedRole {
        case "AXTextArea", "AXTextField":
            return 0 // Cmd+Shift+A: cmux Focus TextBox Input toggles back to the terminal.
        case nil, "", "AXApplication", "AXWindow":
            return nil
        default:
            return nil // Left-sidebar and other controls are recovered by the scheduled surface.focus retry.
        }
    }

    static func cmuxTerminalIsApplicationFocused(processIdentifier: pid_t) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        guard let focusedElement = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return false }
        return applicationWindows(applicationElement).contains { window in
            accessibilityTextCandidates(in: window).contains { candidate in
                cmuxTerminalCandidateScore(candidate.snapshot, windowFrame: axFrame(window)) != nil &&
                    CFEqual(candidate.element, focusedElement)
            }
        }
    }

    static func bestCmuxTerminalCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = cmuxTerminalCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func cmuxTerminalCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, candidate.role == "AXTextArea" else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()
        guard semanticText.contains("terminal content area") else { return nil }

        var score = 200
        if candidate.focused { score += 1_000 }
        if candidate.selectedContext { score += 500 }
        if let frame = candidate.frame {
            score += min(100, Int(frame.width * frame.height / 10_000))
            if let windowFrame, frame.intersects(windowFrame) { score += 100 }
        }
        return score
    }

    @discardableResult
    static func focusCmux(
        applicationURL: URL,
        cliURL: URL? = nil,
        runner: CmuxCommandRunner = runCmuxCommand,
        canContinue: () -> Bool = { true },
        terminalFocuser: (String) -> Bool = { _ in true }
    ) -> Bool {
        guard canContinue() else { return false }
        guard let cliURL = cliURL ?? cmuxCLIURL(applicationURL: applicationURL) else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=cli_unavailable")
            return false
        }

        let currentResult = runner(cliURL, ["rpc", "surface.current", "{}"], 1)
        guard !currentResult.timedOut, currentResult.terminationStatus == 0 else {
            let reason = currentResult.timedOut ? "current_timeout" : "current_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return false
        }
        guard canContinue() else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: currentResult.standardOutput) as? [String: Any],
              let surfaceID = payload["surface_id"] as? String,
              UUID(uuidString: surfaceID) != nil,
              let surfaceType = (payload["surface_type"] as? String) ?? (payload["type"] as? String),
              surfaceType.caseInsensitiveCompare("terminal") == .orderedSame
        else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=no_current_terminal")
            return false
        }

        guard let focusParameters = try? JSONSerialization.data(
            withJSONObject: ["surface_id": surfaceID],
            options: [.sortedKeys]
        ), let focusJSON = String(data: focusParameters, encoding: .utf8) else {
            return false
        }
        guard canContinue() else { return false }

        let focusResult = runner(cliURL, ["rpc", "surface.focus", focusJSON], 1)
        guard !focusResult.timedOut, focusResult.terminationStatus == 0 else {
            let reason = focusResult.timedOut ? "focus_timeout" : "focus_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return false
        }
        guard canContinue() else { return false }
        return terminalFocuser(surfaceID)
    }

    static func cmuxCLIURL(
        applicationURL: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates = [
            applicationURL.appendingPathComponent("Contents/bin/cmux"),
            applicationURL.appendingPathComponent("Contents/Resources/bin/cmux"),
        ]
        candidates.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("cmux") })
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/cmux"),
            URL(fileURLWithPath: "/usr/local/bin/cmux"),
        ])

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runCmuxCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> CmuxCommandResult {
        let process = Process()
        let standardOutput = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
        } catch {
            return CmuxCommandResult(terminationStatus: -1, standardOutput: Data(), timedOut: false)
        }

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if completion.wait(timeout: .now() + .milliseconds(100)) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + .milliseconds(100))
            }
            return CmuxCommandResult(terminationStatus: -1, standardOutput: Data(), timedOut: true)
        }

        return CmuxCommandResult(
            terminationStatus: process.terminationStatus,
            standardOutput: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            timedOut: false
        )
    }

    private static func axAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func axString(_ element: AXUIElement, attribute: String) -> String {
        axAttribute(element, attribute: attribute) as? String ?? ""
    }

    private static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        axAttribute(element, attribute: attribute) as? Bool
    }

    private static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = axAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = axAttribute(element, attribute: attribute) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axAttribute(element, attribute: kAXPositionAttribute),
              let sizeValue = axAttribute(element, attribute: kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func axSemanticText(_ element: AXUIElement) -> String {
        [
            axString(element, attribute: kAXIdentifierAttribute),
            axString(element, attribute: kAXTitleAttribute),
            axString(element, attribute: kAXDescriptionAttribute),
            axString(element, attribute: kAXHelpAttribute),
            axString(element, attribute: kAXPlaceholderValueAttribute),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// 参与符号快捷键的修饰键：键码 + 它对应的 CGEventFlags 位。
    private struct SymbolicModifier {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    private static let controlModifier = SymbolicModifier(keyCode: 59, flag: .maskControl)
    private static let commandModifier = SymbolicModifier(keyCode: 55, flag: .maskCommand)
    private static let shiftModifier = SymbolicModifier(keyCode: 56, flag: .maskShift)

    /// 投递 WindowServer 符号快捷键（调度中心、切换桌面、锁屏、系统截屏等）。
    ///
    /// 这类快捷键匹配的是**真实按键流里的修饰键状态**，不是事件自带的 `flags`。
    /// 只发「目标键 down/up + flags」会被静默丢弃：动作执行了、事件也投递了，
    /// 系统毫无反应。macOS 27.0.1 (26A434) 实测确认。
    ///
    /// 因此这里按真实键入顺序先按下修饰键，再按目标键，最后逆序抬起；
    /// 两次 12ms 停顿让 WindowServer 的修饰键状态机落地，不加会偶发丢动作。
    ///
    /// - Parameter keyFlags: 目标键自身固有的标志位。方向键在真实键盘上恒带
    ///   `SecondaryFn | NumericPad`（见 `MACOS_FUNCTION_LAYER.md`），普通字母键不需要。
    private static func postSymbolicHotKey(
        _ key: CGKeyCode,
        modifiers: [SymbolicModifier],
        keyFlags: CGEventFlags = [],
        keyStatePoster: KeyStatePoster
    ) -> Bool {
        var active: CGEventFlags = []
        for modifier in modifiers {
            active.insert(modifier.flag)
            _ = keyStatePoster(modifier.keyCode, true, active)
        }
        usleep(12_000)
        let effective = active.union(keyFlags)
        _ = keyStatePoster(key, true, effective)
        _ = keyStatePoster(key, false, effective)
        usleep(12_000)
        for modifier in modifiers.reversed() {
            active.remove(modifier.flag)
            _ = keyStatePoster(modifier.keyCode, false, active)
        }
        return true
    }

    private static func postKey(code: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    static func postKeyState(
        code: CGKeyCode,
        isDown: Bool,
        flags: CGEventFlags
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: isDown)
        else { return false }
        event.flags = flags
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
        return true
    }

    /// Scroll events are delivered to the window under the event location, not
    /// to the focused application, so a remote press must aim at the frontmost
    /// window instead of wherever the mouse happens to rest.
    static func scrollTargetLocation(
        windowFrame: CGRect?,
        mouseLocation: CGPoint
    ) -> CGPoint {
        guard let windowFrame,
              windowFrame.width > 0,
              windowFrame.height > 0
        else { return mouseLocation }
        return CGPoint(x: windowFrame.midX, y: windowFrame.midY)
    }

    /// Picks the largest ordinary window of the given process from a
    /// `CGWindowListCopyWindowInfo` snapshot.
    static func frontmostWindowFrame(
        windowInfo: [[String: Any]],
        processIdentifier: pid_t
    ) -> CGRect? {
        windowInfo
            .filter { entry in
                guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                      owner.int32Value == processIdentifier,
                      let layer = entry[kCGWindowLayer as String] as? NSNumber,
                      layer.intValue == 0
                else { return false }
                return true
            }
            .compactMap { entry -> CGRect? in
                guard let bounds = entry[kCGWindowBounds as String] as? NSDictionary else {
                    return nil
                }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    /// 目标 App 的标准窗口数（含最小化窗口），按辅助功能 subrole 过滤。
    /// CGWindowList 会把菜单栏阴影、1×1 辅助窗口也算进来，不能用来数窗口。
    static func standardWindowCount(processIdentifier: pid_t) -> Int? {
        guard isAccessibilityTrusted else { return nil }
        let element = AXUIElementCreateApplication(processIdentifier)
        return axElements(element, attribute: kAXWindowsAttribute).filter {
            axString($0, attribute: kAXSubroleAttribute) == kAXStandardWindowSubrole as String
        }.count
    }

    static func ordinaryWindowCount(
        windowInfo: [[String: Any]],
        processIdentifier: pid_t
    ) -> Int {
        windowInfo.reduce(into: 0) { count, entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.int32Value == processIdentifier,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue == 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 0,
                  frame.height > 0
            else { return }
            count += 1
        }
    }

    enum MinimizedWindowRestoreResult: String, Equatable {
        case restored
        case skippedNotFrontmost
        case skippedVisibleWindow
        case noMinimizedWindow
        case restoreFailed
        case notTrusted
    }

    /// 系统 ⌘Tab 只切换 App：目标 App 的窗口全部最小化时，切过去只有菜单栏。
    /// 确认后如果前台已是目标 App 却没有可见窗口，就把它的一个最小化窗口拉起来。
    static func restoreMinimizedWindowIfNeeded(
        frontmostBundleIdentifier: String?,
        originBundleIdentifier: String?
    ) -> MinimizedWindowRestoreResult {
        guard let frontmostBundleIdentifier,
              frontmostBundleIdentifier != originBundleIdentifier
        else { return .skippedNotFrontmost }
        guard isAccessibilityTrusted else { return .notTrusted }
        let visibility = applicationVisibilitySnapshot(
            bundleIdentifier: frontmostBundleIdentifier
        )
        if visibility.onscreenWindowCount.map({ $0 > 0 }) == true {
            return .skippedVisibleWindow
        }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: frontmostBundleIdentifier
        ).first(where: { !$0.isTerminated }) else {
            return .noMinimizedWindow
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let windows = axElements(applicationElement, attribute: kAXWindowsAttribute)
        guard let target = windows.first(where: {
            axBool($0, attribute: kAXMinimizedAttribute) == true
        }) else { return .noMinimizedWindow }

        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        application.activate(options: [])
        return axBool(target, attribute: kAXMinimizedAttribute) == false ? .restored : .restoreFailed
    }

    /// 切换器 HUD 的当前高亮项由 Dock 通过辅助功能暴露（`AXSelectedChildren`）。
    /// 一旦进入窗口选择层，这个列表就会消失，所以必须在进入前读取。
    struct AppSwitcherSelection {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
    }

    /// 切换器里选中的 App。同名实例（两个 Chrome）时优先非活跃的那个：
    /// 用户在切换器里选的几乎总是“另一个”App，而不是当前活跃的实例。
    /// 切换器 HUD 的三种状态：可见 / 已消失 / 读不到。
    /// 读不到与“消失”必须区分开：辅助功能读取偶发失败时不能当成 HUD 关闭。
    enum AppSwitcherHudState: Equatable {
        case visible(selectedBundleIdentifier: String?)
        case absent
        case unreadable

        var logLabel: String {
            switch self {
            case .visible(let bundleIdentifier):
                return "visible:\(bundleIdentifier ?? "-")"
            case .absent:
                return "absent"
            case .unreadable:
                return "unreadable"
            }
        }
    }

    private static func appSwitcherHudSelection()
    -> (state: AppSwitcherHudState, application: NSRunningApplication?) {
        guard isAccessibilityTrusted,
              let dock = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.dock"
              ).first
        else { return (.unreadable, nil) }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let elements = axAttribute(
            dockElement,
            attribute: kAXChildrenAttribute
        ) as? [AXUIElement] else { return (.unreadable, nil) }
        guard let list = elements.first(where: {
            axString($0, attribute: kAXSubroleAttribute) == "AXProcessSwitcherList"
        }) else { return (.absent, nil) }
        guard let selected = axElements(
            list,
            attribute: kAXSelectedChildrenAttribute
        ).first else { return (.visible(selectedBundleIdentifier: nil), nil) }
        let title = axString(selected, attribute: kAXTitleAttribute)
        guard !title.isEmpty else { return (.visible(selectedBundleIdentifier: nil), nil) }
        let candidates = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.localizedName == title
        }
        // 同名多实例时优先非活跃的那个：切换器里选中的通常不是当前 App。
        let match = candidates.first(where: { !$0.isActive }) ?? candidates.first
        return (.visible(selectedBundleIdentifier: match?.bundleIdentifier), match)
    }

    /// 切换器里当前高亮的 App 标题（原始标题，不解析成进程）。
    /// 用来判断方向键是否真的移动了高亮。
    static func appSwitcherHighlightedTitle() -> String? {
        guard isAccessibilityTrusted,
              let dock = NSRunningApplication.runningApplications(
                  withBundleIdentifier: "com.apple.dock"
              ).first
        else { return nil }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let elements = axAttribute(
            dockElement,
            attribute: kAXChildrenAttribute
        ) as? [AXUIElement] else { return nil }
        guard let list = elements.first(where: {
            axString($0, attribute: kAXSubroleAttribute) == "AXProcessSwitcherList"
        }) else { return nil }
        guard let selected = axElements(
            list,
            attribute: kAXSelectedChildrenAttribute
        ).first else { return nil }
        let title = axString(selected, attribute: kAXTitleAttribute)
        return title.isEmpty ? nil : title
    }

    /// 切换器 HUD 是否还开着。用来判断会话是否还需要保持 ⌘ 按住。
    static func appSwitcherHudState() -> AppSwitcherHudState {
        appSwitcherHudSelection().state
    }

    static func appSwitcherSelectedApplication() -> AppSwitcherSelection? {
        let selection = appSwitcherHudSelection()
        guard let match = selection.application else { return nil }
        return AppSwitcherSelection(
            processIdentifier: match.processIdentifier,
            bundleIdentifier: match.bundleIdentifier
        )
    }

    /// 把目标 App 带到前台。窗口已经由 Return 打开时，只需要激活 App 本身，
    /// 不要 raise 具体窗口，避免换掉用户选中的窗口。
    static func activateApplication(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else { return false }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
            return true
        }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(processIdentifier),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        _ = application.activate(options: [.activateAllWindows])
        // 双实例时 LaunchServices 会把“有可见窗口的那个实例”带上来，
        // 前台 bundle 已经一致时跳过。
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            != application.bundleIdentifier,
           let url = application.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
        return true
    }

    /// 单窗口场景：窗口层里的高亮不稳定，直接恢复那个唯一窗口并置前。
    /// 按进程操作，双实例 App（两个 Chrome）也能落到正确的实例上。
    static func restoreSingleWindow(processIdentifier: pid_t) -> Bool {
        guard isAccessibilityTrusted,
              let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else { return false }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        let windows = axElements(element, attribute: kAXWindowsAttribute)
        guard let window = windows.first else { return false }
        if axBool(window, attribute: kAXMinimizedAttribute) == true {
            AXUIElementSetAttributeValue(
                window,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        _ = application.activate(options: [.activateAllWindows])
        // LaunchServices 按 bundle 激活：同名双实例时会带上“有可见窗口的那个实例”，
        // 正好符合用户直觉；前台 bundle 已经一致时跳过，避免多一次激活。
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            != application.bundleIdentifier,
           let url = application.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        }
        return true
    }

    static func applicationVisibilitySnapshot(
        bundleIdentifier: String
    ) -> ApplicationVisibilitySnapshot {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard let application = applications.first(where: { $0.isActive && !$0.isTerminated })
            ?? applications.first(where: { !$0.isTerminated })
        else {
            return ApplicationVisibilitySnapshot(
                bundleIdentifier: bundleIdentifier,
                processActive: false,
                processHidden: false,
                processTerminated: true,
                activationPolicy: "unknown",
                ordinaryWindowCount: 0,
                onscreenWindowCount: 0
            )
        }

        let allWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        let onscreenWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        let activationPolicy: String = switch application.activationPolicy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
        return ApplicationVisibilitySnapshot(
            bundleIdentifier: bundleIdentifier,
            processActive: application.isActive,
            processHidden: application.isHidden,
            processTerminated: application.isTerminated,
            activationPolicy: activationPolicy,
            ordinaryWindowCount: allWindows.map {
                ordinaryWindowCount(
                    windowInfo: $0,
                    processIdentifier: application.processIdentifier
                )
            },
            onscreenWindowCount: onscreenWindows.map {
                ordinaryWindowCount(
                    windowInfo: $0,
                    processIdentifier: application.processIdentifier
                )
            }
        )
    }

    private static func frontmostWindowFrame() -> CGRect? {
        guard let processIdentifier = NSWorkspace.shared
            .frontmostApplication?
            .processIdentifier
        else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        if let window = axAttribute(application, attribute: kAXFocusedWindowAttribute),
           CFGetTypeID(window) == AXUIElementGetTypeID(),
           let frame = axFrame(window as! AXUIElement),
           frame.width > 0,
           frame.height > 0 {
            return frame
        }
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return frontmostWindowFrame(
            windowInfo: windowInfo,
            processIdentifier: processIdentifier
        )
    }

    private static func currentMouseLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Positive `lines` scrolls the content toward the beginning of the
    /// conversation, so the up key shows earlier messages.
    private static func postScrollWheel(lines: Int32) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  scrollWheelEvent2Source: source,
                  units: .line,
                  wheelCount: 1,
                  wheel1: lines,
                  wheel2: 0,
                  wheel3: 0
              )
        else { return }
        event.location = scrollTargetLocation(
            windowFrame: frontmostWindowFrame(),
            mouseLocation: currentMouseLocation()
        )
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    private static func postSystemKey(type: Int32) {
        submitSystemKey(type: type)
    }

    @discardableResult
    static func submitSystemKey(
        type: Int32,
        eventPoster: (CGEvent) -> Bool = ShortcutEventSequence.post,
        logger: (String) -> Void = AppLogger.shared.write
    ) -> Bool {
        let operationID = UUID().uuidString
        let kind: String?
        switch type {
        case 16: kind = "play_pause"
        case 17: kind = "next_track"
        case 18: kind = "previous_track"
        default: kind = nil
        }
        // Keep volume repeats on their existing path without extra media logs.
        func log(_ message: String) {
            if kind != nil { logger(message) }
        }
        let prefix = "SYSTEM MEDIA operation_id=\(operationID) action=\(kind ?? "other") " +
            "target=system_media_dispatch"
        log("\(prefix) phase=requested post_tap=hid user_visible_result=unknown")
        var submitted = 0
        var reason = "none"
        for (index, isDown) in [true, false].enumerated() {
            let edge = isDown ? "down" : "up"
            let keyState = isDown ? 0xA : 0xB
            let data1 = Int((type << 16) | Int32(keyState << 8))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            ), let cgEvent = event.cgEvent else {
                reason = "construction_failed"
                log("\(prefix) phase=event_submission event_index=\(index + 1) edge=\(edge) result=construction_failed")
                continue
            }
            cgEvent.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            if let kind {
                ShortcutSessionObservation.shared.register(cgEvent, operationID: operationID,
                    eventIndex: index + 1, primaryKind: "system_\(kind)")
            }
            let accepted = eventPoster(cgEvent)
            if accepted { submitted += 1 }
            else {
                reason = "post_failed"
                if kind != nil { ShortcutSessionObservation.shared.discard(operationID: operationID, eventIndex: index + 1) }
            }
            log("\(prefix) phase=event_submission event_index=\(index + 1) edge=\(edge) " +
                "event_timestamp_ns=\(cgEvent.timestamp) result=\(accepted ? "submitted" : "failed")")
        }
        let succeeded = submitted == 2
        log("\(prefix) phase=completed result=\(succeeded ? "submitted" : "failed") reason=\(reason) " +
            "submitted_events=\(submitted) user_visible_result=unknown")
        return succeeded
    }

}

final class ApplicationFocusRequestGate {
    private let lock = NSLock()
    private var latestRequestID: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        latestRequestID &+= 1
        return latestRequestID
    }

    func isCurrent(_ requestID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requestID == latestRequestID
    }
}
