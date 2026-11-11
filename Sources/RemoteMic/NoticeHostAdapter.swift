#if canImport(SayAllHostBridge)
import SayAllHostBridge
import SwiftUI

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
            // 常用语面板固定纯黑外观，气泡必须用深色那一套；
            // 不显式指定会跟随系统浅色，在黑底上变成亮色块。
            .environment(\.colorScheme, .dark)
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
