// VoiceKeyFnPanelProbe —— 判定「第三方语音工具（豆包/微信输入法等）当前生效的 Fn 语音键语义」
//
// 背景（2026-09-18 夜实测）：用户报告「按一下结束，遥控器灯灭但豆包电平图不消失，要再按一下」。
// 日志证明宿主结束逻辑一步不缺，于是需要单独回答一个问题：
//   「Fn 的『按下』与『松开』，哪一个才是目标工具结束收音的条件？」
//
// 本工具直接把 Fn 键事件注入系统（与宿主 KeyboardInjector.postKeyState 完全相同的
// CGEventSource(.hidSystemState) + post(tap: .cghidEventTap)），并每 250ms 采样
// CGWindowListCopyWindowInfo 中豆包进程 layer=3 的窗口（= 语音面板）是否在场。
//
// 用法（无需遥控器，约 20 秒）：
//   swift Testing/VoiceKeyFnPanelProbe.swift
// 判读：
//   按下出现、松开消失            → 目标工具是「长按模式」，宿主「按住—松开」语义正确
//   按下出现、松开仍在、再按下消失 → 目标工具是「点按（开关）模式」，
//                                   需要改目标工具设置或把宿主改成「成对 Fn 点按」驱动
// 说明：本工具只读窗口列表 + 注入 Fn 键，不修改任何配置；结束前一定会释放 Fn。
import AppKit
import CoreGraphics
import Foundation

let fnKeyCode: CGKeyCode = 63
let sampleInterval: useconds_t = 250_000

/// 目标工具进程（默认豆包输入法；换工具时改这里的匹配串）
let targetMatchers: [(NSRunningApplication) -> Bool] = [
    { ($0.bundleIdentifier ?? "").contains("doubao") },
    { ($0.localizedName ?? "").contains("豆包") }
]

func targetPIDs() -> [pid_t] {
    let apps = NSWorkspace.shared.runningApplications
    return apps.filter { app in targetMatchers.contains { $0(app) } }.map { $0.processIdentifier }
}

/// 目标工具的语音面板：主进程 layer == 3 的小窗（实测 124x32）
func panelVisible(pids: [pid_t]) -> Bool {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return false }
    return list.contains { window in
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid) else {
            return false
        }
        return (window[kCGWindowLayer as String] as? Int ?? -1) == 3
    }
}

func fnFlagDown() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
}

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: Date())
}

/// 与宿主 KeyboardInjector.postKeyState 相同的注入方式（keyDown/keyUp）
func postFnAsKey(_ down: Bool) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(keyboardEventSource: source, virtualKey: fnKeyCode, keyDown: down)
    else { return }
    event.flags = down ? [.maskSecondaryFn] : []
    event.post(tap: .cghidEventTap)
}

/// 修饰键的另一种表达：flagsChanged（用于对照「注入方式是否影响结论」）
func postFnAsFlagsChanged(_ down: Bool) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let event = CGEvent(source: source)
    else { return }
    event.type = .flagsChanged
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(fnKeyCode))
    event.flags = down ? [.maskSecondaryFn] : []
    event.post(tap: .cghidEventTap)
}

func watch(_ seconds: Double, label: String, pids: [pid_t]) {
    let steps = max(Int(seconds / 0.25), 1)
    for index in 1...steps {
        usleep(sampleInterval)
        print(
            "\(stamp()) [\(label) \(index * 250)ms] "
                + "fn修饰位=\(fnFlagDown() ? "DOWN" : "up") "
                + "语音面板=\(panelVisible(pids: pids) ? "在" : "无")"
        )
    }
}

let pids = targetPIDs()
print("=== 目标工具 pid: \(pids)（空 = 工具未运行）  辅助功能可信: \(AXIsProcessTrusted()) ===")
watch(0.5, label: "基线", pids: pids)

print("\n########## 变体 A：keyDown 按下 → 保持 1.5s → keyUp 松开 ##########")
print(">>> keyDown")
postFnAsKey(true)
watch(1.5, label: "A按下后", pids: pids)
print(">>> keyUp")
postFnAsKey(false)
watch(2.5, label: "A松开后", pids: pids)
print(">>> 再按一次 keyDown（判定是否按『按下』切换）")
postFnAsKey(true)
watch(1.5, label: "A二次按下后", pids: pids)
postFnAsKey(false)
usleep(sampleInterval)
watch(0.5, label: "A清理后", pids: pids)

print("\n########## 变体 B：flagsChanged 按下 → 保持 1.5s → flagsChanged 松开 ##########")
print(">>> flagsChanged DOWN")
postFnAsFlagsChanged(true)
watch(1.5, label: "B按下后", pids: pids)
print(">>> flagsChanged UP")
postFnAsFlagsChanged(false)
watch(2.5, label: "B松开后", pids: pids)
print(">>> 再按一次 flagsChanged DOWN")
postFnAsFlagsChanged(true)
watch(1.5, label: "B二次按下后", pids: pids)
postFnAsFlagsChanged(false)
usleep(sampleInterval)
print("=== 结束（Fn 已释放）。判读见文件头注释 ===")
