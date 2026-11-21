#if canImport(SayAllHostBridge)
import AppKit
import SayAllHostBridge
import SwiftUI

/// 关掉私有宿主透明提示窗的系统阴影。
///
/// 私有侧把气泡放进无边框透明面板后，系统窗口阴影会沿气泡的不透明轮廓
/// 在四周画出一大块灰色圆角底。气泡自身的设计阴影已经足够表达层级；
/// 这里只关闭承载窗口的阴影，不改变气泡样式。
private struct NoticeHostWindowShadowSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SuppressorView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SuppressorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.hasShadow = false
        }
    }
}

/// 把私有侧的能力请求翻译成公开仓的提示气泡。
///
/// 只在私有桥可用时编译。公开构建（`SAYALL_ENABLE_PRIVATE_SWIFTPM=0`）里整段不参与，
/// 因此没有私有权限的贡献者仍能正常构建与测试。
final class NoticeHostAdapter: HostNoticePresenting {
    @MainActor
    func makeNoticeView(
        _ request: HostNoticeRequest,
        callbacks: HostNoticeCallbacks
    ) -> AnyView {
        let action = request.actionTitle.map { title in
            NoticeAction(title: title) {
                callbacks.onAction?()
            }
        }
        return AnyView(
            NoticeBubble(
                tier: request.tone.noticeTier,
                title: request.title,
                text: request.message,
                action: action,
                onClose: { callbacks.onDismiss?() }
            )
            // 失败提示是独立透明窗，不在常用语面板内。
            // 跟随系统外观；面板本身仍保持纯黑。
            .background(NoticeHostWindowShadowSuppressor())
        )
    }
}

extension HostNoticeRequest.Tone {
    var noticeTier: NoticeTier {
        switch self {
        case .tip: return .tip
        case .warning: return .warning
        case .error: return .error
        }
    }
}
#endif
