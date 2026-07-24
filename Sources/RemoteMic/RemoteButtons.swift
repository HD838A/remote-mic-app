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

    var shortLabel: String {
        switch self {
        case .power: return "电源"
        case .up: return "上"
        case .left: return "左"
        case .ok: return "OK"
        case .right: return "右"
        case .down: return "下"
        case .back: return "返回"
        case .volumeUp: return "+"
        case .home: return "主页"
        case .volumeDown: return "−"
        case .menu: return "菜单"
        case .tv: return "TV"
        }
    }

    var displayName: String {
        switch self {
        case .power: return "电源键"
        case .up: return "上键"
        case .left: return "左键"
        case .ok: return "确定键"
        case .right: return "右键"
        case .down: return "下键"
        case .back: return "返回键"
        case .volumeUp: return "音量 +"
        case .home: return "主页键"
        case .volumeDown: return "音量 -"
        case .menu: return "菜单键"
        case .tv: return "TV 键"
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

    var displayName: String {
        switch self {
        case .remoteMic: return "无线麦"
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .cmux: return "cmux"
        case .weChat: return "微信"
        case .cursor: return "Cursor"
        case .xcode: return "Xcode"
        case .slack: return "Slack"
        case .weCom: return "企业微信"
        case .neteaseMusic: return "网易云音乐"
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

    var displayName: String {
        switch self {
        case .disabled: return "禁用"
        case .escape: return "Escape"
        case .returnKey: return "Return"
        case .arrowUp: return "方向上"
        case .arrowDown: return "方向下"
        case .arrowLeft: return "方向左"
        case .arrowRight: return "方向右"
        case .deleteBackward: return "Delete（退格）"
        case .showDesktop: return "显示桌面"
        case .contextMenu: return "上下文菜单"
        case .appSwitcher: return "Command-Tab"
        case .volumeUp: return "系统音量 +"
        case .volumeDown: return "系统音量 -"
        case .volumeMute: return "系统静音"
        case .playPause: return "播放 / 暂停"
        case .openRemoteMic: return "打开无线麦"
        case .openCodex: return "打开 Codex"
        case .openClaude: return "打开 Claude"
        case .openCmux: return "打开 cmux"
        case .openWeChat: return "打开微信"
        case .openCursor: return "打开 Cursor"
        case .openXcode: return "打开 Xcode"
        case .openSlack: return "打开 Slack"
        case .openWeCom: return "打开企业微信"
        case .openNeteaseMusic: return "打开网易云音乐"
        case .openChrome: return "打开 Chrome"
        case .openSafari: return "打开 Safari"
        case .openZed: return "打开 Zed"
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
