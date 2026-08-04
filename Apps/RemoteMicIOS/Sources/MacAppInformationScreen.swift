import SwiftUI
import UIKit

struct MacAppInformationScreen: View {
    private struct CheckItem: Identifiable {
        let id: String
        let title: String
        let isReady: Bool
    }

    private static let downloadURL = "https://github.com/HD838A/remote-mic-app/releases/latest"
    private static let chineseWebsiteURL = URL(string: "https://8586ai.com/")!
    private static let englishWebsiteURL = URL(string: "https://8586ai.com/en/")!

    @EnvironmentObject private var connection: RemoteMacConnection
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyLink = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.height < 780
            let sectionSpacing: CGFloat = 10

            ZStack {
                RemoteBackground()

                VStack(spacing: sectionSpacing) {
                    navigationBar
                        .frame(height: 44)

                    identityHeader
                        .frame(height: isCompact ? 68 : 74)

                    connectionDetails
                        .frame(height: isCompact ? 122 : 132)

                    connectionChecks
                        .frame(height: isCompact ? 92 : 100)

                    remoteRecommendation
                        .frame(height: isCompact ? 86 : 94)

                    downloadSection
                        .frame(height: isCompact ? 188 : 202)
                }
                .frame(maxWidth: 520, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.vertical, isCompact ? 4 : 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .preferredColorScheme(.light)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(edgeBackGesture)
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text("无线麦")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(RemotePalette.text)

            HStack {
                Button {
                    dismiss()
                } label: {
                    InformationLightSurface(cornerRadius: 10) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.9))
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("返回遥控器")

                Spacer()

                Button {
                    HapticFeedback.shared.trigger(.emphasized)
                    connection.restartDiscovery()
                } label: {
                    InformationLightSurface(cornerRadius: 10) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.9))
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("重新连接 Mac")
            }
        }
    }

    private var identityHeader: some View {
        HStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .clipShape(AppIconRoundedRectangle())
                .overlay {
                    AppIconRoundedRectangle()
                        .stroke(Color.white.opacity(0.8), lineWidth: 1)
                }
                .overlay {
                    AppIconRoundedRectangle()
                        .stroke(Color.black.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 3)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)
                    Text(connection.statusText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                Text(connection.macName)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(RemotePalette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(macAppSummary)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(RemotePalette.text.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
    }

    private var connectionDetails: some View {
        InformationLightSurface(cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("连接详情")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(RemotePalette.text.opacity(0.78))

                HStack(spacing: 0) {
                    detailItem("Mac App", value: macAppDetail)
                    Divider()
                    detailItem("连接方式", value: connectionMethod)
                }

                Divider()

                HStack(spacing: 0) {
                    detailItem("配对状态", value: pairingStatus)
                    Divider()
                    detailItem("最近连接", value: lastConnectionText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var connectionChecks: some View {
        InformationLightSurface(cornerRadius: 14) {
            VStack(spacing: 8) {
                HStack {
                    Text("连接检查")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RemotePalette.text.opacity(0.78))

                    Spacer()

                    Button {
                        HapticFeedback.shared.trigger(.emphasized)
                        connection.restartDiscovery()
                    } label: {
                        Text("重新检查")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.78))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.26))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.black.opacity(0.18), lineWidth: 1)
                            }
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityLabel("重新检查连接")
                }

                HStack(spacing: 0) {
                    ForEach(Array(checkItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                                .padding(.vertical, 2)
                        }
                        VStack(spacing: 5) {
                            Image(systemName: item.isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundStyle(item.isReady ? Color.green : Color.orange)
                            Text(item.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(RemotePalette.text.opacity(0.78))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var remoteRecommendation: some View {
        InformationLightSurface(cornerRadius: 14) {
            HStack(spacing: 12) {
                Image(systemName: "av.remote.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(RemotePalette.text.opacity(0.82))
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("推荐实体麦克风遥控器")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(RemotePalette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Text("日常推荐")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.64))
                            .padding(.horizontal, 7)
                            .frame(height: 23)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.22))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.black.opacity(0.14), lineWidth: 1)
                            }
                    }

                    Text("iPhone 适合临时应急；实体遥控器更适合盲操，\n按键反馈更清楚，也更稳定。")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RemotePalette.text.opacity(0.66))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var downloadSection: some View {
        InformationLightSurface(cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("下载 Mac App")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RemotePalette.text)
                    Text("Apple Silicon · macOS 14 或更高版本")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RemotePalette.text.opacity(0.62))

                    HStack(spacing: 10) {
                        Link("中文官网", destination: Self.chineseWebsiteURL)
                        Link("English", destination: Self.englishWebsiteURL)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(RemotePalette.text.opacity(0.78))
                }

                ShareLink(
                    item: Self.downloadURL,
                    subject: Text("无线麦 Mac App"),
                    message: Text("无线麦 Mac App 最新版下载链接")
                ) {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .semibold))
                        Text(Self.downloadURL.replacingOccurrences(of: "https://", with: ""))
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(RemotePalette.text.opacity(0.84))
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.26))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.black.opacity(0.17), lineWidth: 1)
                    }
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel("分享 GitHub 最新版下载链接")

                HStack(spacing: 10) {
                    ShareLink(
                        item: Self.downloadURL,
                        subject: Text("无线麦 Mac App"),
                        message: Text("无线麦 Mac App 最新版下载链接")
                    ) {
                        InformationGraphiteSurface(cornerRadius: 10) {
                            HStack(spacing: 7) {
                                Image(systemName: "airplayaudio")
                                    .font(.system(size: 18, weight: .semibold))
                                Text("发送链接到 Mac")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                            .foregroundStyle(.white.opacity(0.94))
                        }
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityLabel("通过 AirDrop 或系统分享发送下载链接")

                    Button {
                        copyDownloadLink()
                    } label: {
                        InformationLightSurface(cornerRadius: 10) {
                            HStack(spacing: 7) {
                                Image(systemName: didCopyLink ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 17, weight: .semibold))
                                Text(didCopyLink ? "已复制" : "复制链接")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(RemotePalette.text.opacity(0.9))
                        }
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityLabel(didCopyLink ? "下载链接已复制" : "复制下载链接")
                }
                .frame(height: 46)

                Divider()

                HStack(spacing: 7) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 14, weight: .semibold))
                    Text("语音仅在按住时传输，不会上传。")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(RemotePalette.text.opacity(0.58))
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var edgeBackGesture: some Gesture {
        DragGesture(minimumDistance: 16, coordinateSpace: .global)
            .onEnded { value in
                guard value.startLocation.x <= 24,
                      value.translation.width >= 80,
                      abs(value.translation.height) <= 60
                else { return }
                dismiss()
            }
    }

    private func detailItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(RemotePalette.text.opacity(0.82))
            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(RemotePalette.text.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkItems: [CheckItem] {
        [
            CheckItem(
                id: "app",
                title: hasDiscoveredMac ? "App 已打开" : "等待 App",
                isReady: hasDiscoveredMac
            ),
            CheckItem(
                id: "network",
                title: connection.isNearbyNetworkReady ? "网络可用" : "检查网络",
                isReady: connection.isNearbyNetworkReady
            ),
            CheckItem(
                id: "approval",
                title: connection.isConnected ? "iPhone 已授权" : "等待授权",
                isReady: connection.isConnected
            )
        ]
    }

    private var statusColor: Color {
        switch connection.state {
        case .connected:
            return .green
        case .connectedWithError, .awaitingLocalNetworkPermission, .unavailable:
            return .orange
        case .searching, .connecting, .awaitingApproval:
            return .orange
        }
    }

    private var macAppSummary: String {
        switch connection.state {
        case .connected, .connectedWithError:
            return "无线麦 Mac App 正在运行"
        case .connecting:
            return "正在建立附近安全连接"
        case .awaitingApproval:
            return "请在 Mac 上确认验证码"
        case .awaitingLocalNetworkPermission:
            return "请允许本地网络访问"
        case .searching:
            return "打开 Mac 上的无线麦后会自动出现"
        case .unavailable:
            return "请确认 Mac App 已打开"
        }
    }

    private var macAppDetail: String {
        if let version = connection.macAppVersion, connection.isConnected {
            return version
        }
        switch connection.state {
        case .connected, .connectedWithError:
            return "正在运行"
        case .connecting, .awaitingApproval:
            return "已发现"
        default:
            return "正在查找"
        }
    }

    private var connectionMethod: String {
        connection.isConnected ? "附近安全连接" : "等待连接"
    }

    private var pairingStatus: String {
        switch connection.state {
        case .connected, .connectedWithError:
            return "已信任"
        case .awaitingApproval:
            return "等待确认"
        default:
            return "未授权"
        }
    }

    private var lastConnectionText: String {
        if connection.isConnected {
            return "刚刚"
        }
        guard let lastConnectedAt = connection.lastConnectedAt else {
            return "尚无"
        }
        let minutes = max(1, Int(Date().timeIntervalSince(lastConnectedAt) / 60))
        return minutes < 60 ? "\(minutes) 分钟前" : "今天"
    }

    private var hasDiscoveredMac: Bool {
        switch connection.state {
        case .connecting, .awaitingApproval, .connected, .connectedWithError:
            return true
        case .searching, .awaitingLocalNetworkPermission, .unavailable:
            return false
        }
    }

    private func copyDownloadLink() {
        UIPasteboard.general.string = Self.downloadURL
        HapticFeedback.shared.trigger(.emphasized)
        didCopyLink = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopyLink = false
        }
    }
}

private struct InformationLightSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [RemotePalette.lightTop, RemotePalette.lightBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1)
                .padding(1)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.23), lineWidth: 1.3)
            content
        }
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 3)
    }
}

private struct InformationGraphiteSurface<Content: View>: View {
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content

    init(cornerRadius: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [RemotePalette.graphiteTop, RemotePalette.graphiteBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                .padding(1)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(RemotePalette.graphiteEdge, lineWidth: 1.5)
            content
        }
        .shadow(color: .black.opacity(0.19), radius: 4, x: 0, y: 3)
    }
}

#Preview("Mac App Information") {
    NavigationStack {
        MacAppInformationScreen()
            .environmentObject(RemoteMacConnection())
    }
}
