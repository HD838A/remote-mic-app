import AppKit
import Foundation

enum RemoteButton: String, CaseIterable, Codable, Identifiable {
    case power
    case up
    case left
    case ok
    case right
    case down
    case back
    case volumeUp = "volume_up"
    case home
    case volumeDown = "volume_down"
    case menu
    case tv

    var id: String { rawValue }

    var hidUsage: UInt16 {
        switch self {
        case .power: return 0x66
        case .up: return 0x52
        case .left: return 0x50
        case .ok: return 0x28
        case .right: return 0x4F
        case .down: return 0x51
        case .back: return 0xF1
        case .volumeUp: return 0x80
        case .home: return 0x4A
        case .volumeDown: return 0x81
        case .menu: return 0x65
        case .tv: return 0x35
        }
    }

    func shortLabel(using localization: LocalizationStore) -> String {
        switch self {
        case .power: return localization.text("电源")
        case .up: return localization.text("上")
        case .left: return localization.text("左")
        case .ok: return "OK"
        case .right: return localization.text("右")
        case .down: return localization.text("下")
        case .back: return localization.text("返回")
        case .volumeUp: return "+"
        case .home: return localization.text("主页")
        case .volumeDown: return "−"
        case .menu: return localization.text("菜单")
        case .tv: return "TV"
        }
    }

    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .power: return localization.text("电源键")
        case .up: return localization.text("上键")
        case .left: return localization.text("左键")
        case .ok: return localization.text("确定键")
        case .right: return localization.text("右键")
        case .down: return localization.text("下键")
        case .back: return localization.text("返回键")
        case .volumeUp: return localization.text("音量 +")
        case .home: return localization.text("主页键")
        case .volumeDown: return localization.text("音量 -")
        case .menu: return localization.text("菜单键")
        case .tv: return localization.text("TV 键")
        }
    }

    static let usageMap = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.hidUsage, $0) }
    )

    static func buttons(for usages: Set<UInt16>) -> Set<RemoteButton> {
        Set(usages.compactMap { usageMap[$0] })
    }

    var nativeEvent: RemoteNativeEvent? {
        switch self {
        case .ok: return .keyboard(keyCode: 36)
        case .tv: return .keyboard(keyCode: 50)
        case .home: return .keyboard(keyCode: 115)
        case .right: return .keyboard(keyCode: 124)
        case .left: return .keyboard(keyCode: 123)
        case .down: return .keyboard(keyCode: 125)
        case .up: return .keyboard(keyCode: 126)
        case .menu: return .keyboard(keyCode: 110)
        case .power: return .systemKey(type: 6)
        case .volumeUp: return .systemKey(type: 0)
        case .volumeDown: return .systemKey(type: 1)
        case .back: return nil
        }
    }
}

enum RemoteNativeEvent: Equatable {
    case keyboard(keyCode: UInt16)
    case systemKey(type: Int32)
}

enum RemoteEventEdge: Equatable {
    case down
    case up
}

struct CustomKeyboardShortcut: Codable, Equatable {
    static let supportedModifiers: NSEvent.ModifierFlags = [
        .control, .option, .shift, .command, .function,
    ]

    let keyCode: UInt16
    let modifierFlagsRawValue: UInt
    let keyLabel: String

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        modifierFlagsRawValue = modifierFlags.intersection(Self.supportedModifiers).rawValue
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            keyLabel: Self.keyLabel(for: event)
        )
    }

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
            .intersection(Self.supportedModifiers)
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if modifierFlags.contains(.control) { flags.insert(.maskControl) }
        if modifierFlags.contains(.option) { flags.insert(.maskAlternate) }
        if modifierFlags.contains(.shift) { flags.insert(.maskShift) }
        if modifierFlags.contains(.command) { flags.insert(.maskCommand) }
        if modifierFlags.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }

    func displayName(using localization: LocalizationStore) -> String {
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option) { result += "⌥" }
        if modifierFlags.contains(.shift) { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        if modifierFlags.contains(.function) { result += "fn " }
        return result + localizedKeyLabel(using: localization)
    }

    private func localizedKeyLabel(using localization: LocalizationStore) -> String {
        switch keyCode {
        case 36: return localization.text("Return")
        case 48: return localization.text("Tab")
        case 49: return localization.text("Space")
        case 71: return localization.text("Clear")
        case 76: return localization.text("Enter")
        case 114: return localization.text("Help")
        case 115: return localization.text("Home")
        case 116: return localization.text("Page Up")
        case 119: return localization.text("End")
        case 121: return localization.text("Page Down")
        default:
            if keyLabel.hasPrefix("键码 "), let keyCode = Int(keyLabel.dropFirst(3)) {
                return String(
                    format: localization.text("键码 %@"),
                    locale: localization.locale,
                    arguments: [String(keyCode)]
                )
            }
            return keyLabel
        }
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 64: return "F17"
        case 71: return "Clear"
        case 76: return "Enter"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "⌦"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let characters = event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "Key Code \(event.keyCode)" : characters.uppercased()
        }
    }
}

enum ButtonTrigger: String, CaseIterable, Codable, Identifiable {
    case singleClick
    case doubleClick
    case longPress

    var id: String { rawValue }

    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .singleClick: return localization.text("单击")
        case .doubleClick: return localization.text("双击")
        case .longPress: return localization.text("长按")
        }
    }
}

struct ConfiguredButtonAction: Codable, Equatable {
    var action: ButtonAction
    var shortcut: CustomKeyboardShortcut?

    static let disabled = ConfiguredButtonAction(action: .disabled, shortcut: nil)
}

enum ApplicationFocusStrategy: Equatable {
    case accessibilityComposer
    case cmuxSurfaceAPI
}

enum PresetApplication: String, CaseIterable, Identifiable {
    case remoteMic
    case codex
    case claude
    case cmux
    case weChat
    case cursor
    case xcode
    case slack
    case weCom
    case neteaseMusic
    case chrome
    case safari
    case zed

    var id: String { rawValue }

    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .remoteMic: return localization.text("无线麦")
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cmux: return "cmux"
        case .weChat: return localization.text("微信")
        case .cursor: return "Cursor"
        case .xcode: return "Xcode"
        case .slack: return "Slack"
        case .weCom: return localization.text("企业微信")
        case .neteaseMusic: return localization.text("网易云音乐")
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .zed: return "Zed"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .remoteMic: return "com.hd838a.RemoteMic"
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        case .cmux: return "com.cmuxterm.app"
        case .weChat: return "com.tencent.xinWeChat"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .xcode: return "com.apple.dt.Xcode"
        case .slack: return "com.tinyspeck.slackmacgap"
        case .weCom: return "com.tencent.WeWorkMac"
        case .neteaseMusic: return "com.netease.163music"
        case .chrome: return "com.google.Chrome"
        case .safari: return "com.apple.Safari"
        case .zed: return "dev.zed.Zed"
        }
    }

    var focusStrategy: ApplicationFocusStrategy? {
        switch self {
        case .codex, .claude: return .accessibilityComposer
        case .cmux: return .cmuxSurfaceAPI
        default: return nil
        }
    }

    static var installedBundleIdentifiers: Set<String> {
        var identifiers: Set<String> = [remoteMic.bundleIdentifier]
        identifiers.formUnion(allCases.compactMap { application in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier)
                .map { _ in application.bundleIdentifier }
        })
        return identifiers
    }
}

enum ButtonAction: String, CaseIterable, Codable, Identifiable {
    case disabled
    case escape
    case returnKey
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case deleteBackward
    case showDesktop
    case contextMenu
    case appSwitcher
    case volumeUp
    case volumeDown
    case volumeMute
    case playPause
    case customShortcut
    case openRemoteMic
    case openCodex
    case openClaude
    case openCmux
    case openWeChat
    case openCursor
    case openXcode
    case openSlack
    case openWeCom
    case openNeteaseMusic
    case openChrome
    case openSafari
    case openZed

    var id: String { rawValue }

    func displayName(using localization: LocalizationStore) -> String {
        switch self {
        case .disabled: return localization.text("禁用")
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .arrowUp: return localization.text("方向上")
        case .arrowDown: return localization.text("方向下")
        case .arrowLeft: return localization.text("方向左")
        case .arrowRight: return localization.text("方向右")
        case .deleteBackward: return localization.text("Delete（退格）")
        case .showDesktop: return localization.text("显示桌面")
        case .contextMenu: return localization.text("上下文菜单")
        case .appSwitcher: return "Command-Tab"
        case .volumeUp: return localization.text("系统音量 +")
        case .volumeDown: return localization.text("系统音量 -")
        case .volumeMute: return localization.text("系统静音")
        case .playPause: return localization.text("播放 / 暂停")
        case .customShortcut: return localization.text("自定义快捷键")
        case .openRemoteMic: return localization.text("打开无线麦")
        case .openCodex: return localization.text("打开 Codex")
        case .openClaude: return localization.text("打开 Claude")
        case .openCmux: return localization.text("打开 cmux")
        case .openWeChat: return localization.text("打开微信")
        case .openCursor: return localization.text("打开 Cursor")
        case .openXcode: return localization.text("打开 Xcode")
        case .openSlack: return localization.text("打开 Slack")
        case .openWeCom: return localization.text("打开企业微信")
        case .openNeteaseMusic: return localization.text("打开网易云音乐")
        case .openChrome: return localization.text("打开 Chrome")
        case .openSafari: return localization.text("打开 Safari")
        case .openZed: return localization.text("打开 Zed")
        }
    }

    var presetApplication: PresetApplication? {
        switch self {
        case .openRemoteMic: return .remoteMic
        case .openCodex: return .codex
        case .openClaude: return .claude
        case .openCmux: return .cmux
        case .openWeChat: return .weChat
        case .openCursor: return .cursor
        case .openXcode: return .xcode
        case .openSlack: return .slack
        case .openWeCom: return .weCom
        case .openNeteaseMusic: return .neteaseMusic
        case .openChrome: return .chrome
        case .openSafari: return .safari
        case .openZed: return .zed
        default: return nil
        }
    }

    var allowsRepeat: Bool {
        presetApplication == nil
    }

    static func pickerActions(
        installedBundleIdentifiers: Set<String>,
        current: ButtonAction
    ) -> [ButtonAction] {
        allCases.filter { action in
            guard let application = action.presetApplication else { return true }
            return installedBundleIdentifiers.contains(application.bundleIdentifier) || action == current
        }
    }
}

enum RemoteHIDReportParser {
    static func usages(reportID: UInt32, data: Data) -> Set<UInt16>? {
        guard reportID == 1 else { return nil }
        var bytes = Array(data)
        if bytes.count == 7, bytes.first == UInt8(reportID) {
            bytes.removeFirst()
        }
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }

        var result = Set<UInt16>()
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let usage = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            if usage != 0 { result.insert(usage) }
        }
        return result
    }
}

enum HIDPermissionGate {
    static func canMonitor(
        mappingEnabled: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> Bool {
        mappingEnabled && inputMonitoringGranted && accessibilityGranted
    }

    static func nextPermissionRequest(
        mappingEnabled: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> HIDPermissionRequest {
        guard mappingEnabled else { return .none }
        if !inputMonitoringGranted { return .inputMonitoring }
        if !accessibilityGranted { return .accessibility }
        return .none
    }
}

enum HIDPermissionRequest: Equatable {
    case none
    case inputMonitoring
    case accessibility
}
