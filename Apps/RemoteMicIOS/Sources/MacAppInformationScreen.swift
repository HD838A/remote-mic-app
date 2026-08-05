import SwiftUI
import UIKit

struct MacAppInformationScreen: View {
    private struct CheckItem: Identifiable {
        let id: String
        let title: String
        let isReady: Bool
    }

    private static let chineseWebsiteURL = URL(string: "https://8586ai.com/")!
    private static let englishWebsiteURL = URL(string: "https://8586ai.com/en/")!
    static let testFlightURL = URL(string: "https://testflight.apple.com/join/J8k8fb7v")!
    static func websiteURL(for language: AppLanguage) -> URL {
        language == .chinese ? chineseWebsiteURL : englishWebsiteURL
    }

    static func websiteDisplayText(for language: AppLanguage) -> String {
        websiteURL(for: language).absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    @EnvironmentObject private var connection: RemoteMacConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @AppStorage(AppLanguage.storageKey) private var storedLanguage = ""
    @State private var didCopyLink = false
    @State private var didCopyTestFlightLink = false
    @State private var didCopyAppVersion = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var testFlightCopyResetTask: Task<Void, Never>?
    @State private var appVersionCopyResetTask: Task<Void, Never>?
    @State private var diagnosticsShareFile: DiagnosticsShareFile?
    @State private var diagnosticsShareURLForCleanup: URL?

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.height < 780
            let pageSpacing: CGFloat = 20

            ZStack {
                RemoteBackground()

                VStack(spacing: 0) {
                    navigationBar
                        .frame(height: 58)
                        .padding(.horizontal, pageSpacing)
                        .padding(.top, isCompact ? 2 : 8)

                    ScrollView {
                        VStack(spacing: pageSpacing) {
                            identityHeader
                                .frame(height: isCompact ? 64 : 74)

                            connectionDetails
                                .frame(height: isCompact ? 118 : 132)

                            connectionChecks
                                .frame(height: isCompact ? 92 : 100)

                            remoteRecommendation
                                .frame(height: isCompact ? 82 : 94)

                            downloadSection
                                .frame(height: isCompact ? 180 : 202)

                            bottomControls
                        }
                        .frame(maxWidth: 520)
                        .padding(.horizontal, pageSpacing)
                        .padding(.top, pageSpacing)
                        .padding(.bottom, max(pageSpacing, proxy.safeAreaInsets.bottom + 8))
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .preferredColorScheme(.light)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(edgeBackGesture)
        .onDisappear {
            copyResetTask?.cancel()
            testFlightCopyResetTask?.cancel()
            appVersionCopyResetTask?.cancel()
        }
        .sheet(item: $diagnosticsShareFile, onDismiss: removeSharedDiagnosticsFile) { file in
            DiagnosticsActivityView(items: [file.url])
        }
    }

    private var navigationBar: some View {
        ZStack {
            Text(language.text("无线麦"))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(RemotePalette.text)

            HStack {
                Button {
                    dismiss()
                } label: {
                    LightSurface {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.9))
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel(language.text("返回遥控器"))

                Spacer()

                Button {
                    HapticFeedback.shared.trigger(.emphasized)
                    connection.restartDiscovery(reason: "navigation_refresh")
                } label: {
                    LightSurface {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(RemotePalette.text.opacity(0.9))
                    }
                    .frame(width: 54, height: 54)
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel(language.text("重新连接 Mac"))
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
                    Text(connection.statusText(for: language))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                Text(connection.macName(for: language))
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
                Text(language.text("连接详情"))
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(RemotePalette.text.opacity(0.78))

                HStack(spacing: 0) {
                    detailItem(language.text("Mac App"), value: macAppDetail)
                    Divider()
                    detailItem(language.text("连接方式"), value: connectionMethod)
                }

                Divider()

                HStack(spacing: 0) {
                    detailItem(language.text("配对状态"), value: pairingStatus)
                    Divider()
                    detailItem(language.text("最近连接"), value: lastConnectionText)
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
                    Text(language.text("连接检查"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RemotePalette.text.opacity(0.78))

                    Spacer()

                    Button {
                        HapticFeedback.shared.trigger(.emphasized)
                        connection.restartDiscovery(reason: "connection_check")
                    } label: {
                        Text(language.text("重新检查"))
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
                    .accessibilityLabel(language.text("重新检查连接"))
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
                        Text(language.text("推荐实体麦克风遥控器"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(RemotePalette.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Text(language.text("日常推荐"))
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

                    Text(language.text("iPhone 适合临时应急；实体遥控器更适合盲操，\n按键反馈更清楚，也更稳定。"))
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
                    Text(language.text("下载 Mac App"))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(RemotePalette.text)
                    Text(language.text("Apple Silicon · macOS 14 或更高版本"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(RemotePalette.text.opacity(0.62))
                }

                Link(destination: websiteURL) {
                    HStack(spacing: 7) {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .semibold))
                        Text(Self.websiteDisplayText(for: language))
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
                .accessibilityLabel(language.text("打开无线麦官网"))

                HStack(spacing: 10) {
                    ShareLink(
                        item: websiteURL,
                        subject: Text(language.text("无线麦官网")),
                        message: Text(language.text("无线麦官网链接"))
                    ) {
                        InformationGraphiteSurface(cornerRadius: 10) {
                            HStack(spacing: 7) {
                                Image(systemName: "airplayaudio")
                                    .font(.system(size: 18, weight: .semibold))
                                Text(language.text("发送链接到 Mac"))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                            }
                            .foregroundStyle(.white.opacity(0.94))
                        }
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityLabel(language.text("通过 AirDrop 或系统分享发送官网链接"))

                    Button {
                        copyWebsiteLink()
                    } label: {
                        InformationLightSurface(cornerRadius: 10) {
                            HStack(spacing: 7) {
                                Image(systemName: didCopyLink ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 17, weight: .semibold))
                                Text(language.text(didCopyLink ? "已复制" : "复制链接"))
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(RemotePalette.text.opacity(0.9))
                        }
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityLabel(language.text(didCopyLink ? "官网链接已复制" : "复制官网链接"))
                }
                .frame(height: 46)

                Divider()

                HStack(spacing: 7) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 14, weight: .semibold))
                    Text(language.text("语音仅在按住时传输，不会上传。"))
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

    private var languageSwitcher: some View {
        InformationLightSurface(cornerRadius: 12) {
            HStack(spacing: 4) {
                ForEach(AppLanguage.allCases, id: \.self) { option in
                    Button {
                        guard option != language else { return }
                        HapticFeedback.shared.trigger(.emphasized)
                        storedLanguage = option.rawValue
                    } label: {
                        Text(option.switchTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                option == language
                                    ? Color.white.opacity(0.96)
                                    : RemotePalette.text.opacity(0.72)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                if option == language {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(RemotePalette.graphiteBottom.opacity(0.9))
                                }
                            }
                    }
                    .buttonStyle(TactileButtonStyle())
                    .accessibilityLabel(language.format("切换到%@", option.switchTitle))
                    .accessibilityAddTraits(option == language ? .isSelected : [])
                }
            }
            .padding(3)
        }
        .frame(maxWidth: 190)
    }

    private var bottomControls: some View {
        VStack(spacing: 10) {
            Button {
                copyTestFlightLink()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: didCopyTestFlightLink ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))

                    Text(language.text("TestFlight 公测"))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: true, vertical: false)

                    Text(Self.testFlightURL.absoluteString)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                }
                .foregroundStyle(RemotePalette.text.opacity(0.72))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
            }
            .buttonStyle(TactileButtonStyle())
            .accessibilityLabel(
                language.text(didCopyTestFlightLink ? "TestFlight 公测链接已复制" : "复制 TestFlight 公测链接")
            )

            languageSwitcher
                .frame(height: 38)

            HStack(spacing: 10) {
                Button {
                    copyAppVersion()
                } label: {
                    InformationLightSurface(cornerRadius: 12) {
                        HStack(spacing: 5) {
                            Image(systemName: didCopyAppVersion ? "checkmark" : "doc.on.doc")
                            Text("iOS \(appVersionText)")
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(RemotePalette.text.opacity(0.76))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel(
                    language.text(didCopyAppVersion ? "App 版本号已复制" : "复制 App 版本号")
                )

                Button {
                    shareDiagnostics()
                } label: {
                    InformationLightSurface(cornerRadius: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.up")
                            Text(language.text("分享诊断日志"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(RemotePalette.text.opacity(0.76))
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .buttonStyle(TactileButtonStyle())
                .accessibilityLabel(language.text("分享诊断日志"))
            }
            .frame(height: 42)
        }
        .frame(maxWidth: .infinity)
    }

    private var websiteURL: URL {
        Self.websiteURL(for: language)
    }

    static func appVersionText(marketingVersion: String?, buildNumber: String?) -> String {
        let version = marketingVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (version?.isEmpty == false ? version : nil, build?.isEmpty == false ? build : nil) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return build
        case (nil, nil): return "—"
        }
    }

    private var appVersionText: String {
        Self.appVersionText(
            marketingVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
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
                title: language.text(hasDiscoveredMac ? "App 已打开" : "等待 App"),
                isReady: hasDiscoveredMac
            ),
            CheckItem(
                id: "network",
                title: language.text(connection.isNearbyNetworkReady ? "网络可用" : "检查网络"),
                isReady: connection.isNearbyNetworkReady
            ),
            CheckItem(
                id: "approval",
                title: language.text(connection.isConnected ? "iPhone 已授权" : "等待授权"),
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
            return language.text("无线麦 Mac App 正在运行")
        case .connecting:
            return language.text("正在建立附近安全连接")
        case .awaitingApproval:
            return language.text("请在 Mac 上确认验证码")
        case .awaitingLocalNetworkPermission:
            return language.text("请允许本地网络访问")
        case .searching:
            return language.text("打开 Mac 上的无线麦后会自动出现")
        case .unavailable:
            return language.text("请确认 Mac App 已打开")
        }
    }

    private var macAppDetail: String {
        if let version = connection.macAppVersion, connection.isConnected {
            return version
        }
        switch connection.state {
        case .connected, .connectedWithError:
            return language.text("正在运行")
        case .connecting, .awaitingApproval:
            return language.text("已发现")
        default:
            return language.text("正在查找")
        }
    }

    private var connectionMethod: String {
        language.text(connection.isConnected ? "附近安全连接" : "等待连接")
    }

    private var pairingStatus: String {
        switch connection.state {
        case .connected, .connectedWithError:
            return language.text("已信任")
        case .awaitingApproval:
            return language.text("等待确认")
        default:
            return language.text("未授权")
        }
    }

    private var lastConnectionText: String {
        if connection.isConnected {
            return language.text("刚刚")
        }
        guard let lastConnectedAt = connection.lastConnectedAt else {
            return language.text("尚无")
        }
        let minutes = max(1, Int(Date().timeIntervalSince(lastConnectedAt) / 60))
        return minutes < 60 ? language.format("%d 分钟前", minutes) : language.text("今天")
    }

    private var hasDiscoveredMac: Bool {
        switch connection.state {
        case .connecting, .awaitingApproval, .connected, .connectedWithError:
            return true
        case .searching, .awaitingLocalNetworkPermission, .unavailable:
            return false
        }
    }

    private func copyWebsiteLink() {
        UIPasteboard.general.url = websiteURL
        HapticFeedback.shared.trigger(.emphasized)
        didCopyLink = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopyLink = false
        }
    }

    private func copyTestFlightLink() {
        UIPasteboard.general.url = Self.testFlightURL
        HapticFeedback.shared.trigger(.emphasized)
        didCopyTestFlightLink = true
        testFlightCopyResetTask?.cancel()
        testFlightCopyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopyTestFlightLink = false
        }
    }

    private func copyAppVersion() {
        UIPasteboard.general.string = appVersionText
        HapticFeedback.shared.trigger(.emphasized)
        didCopyAppVersion = true
        appVersionCopyResetTask?.cancel()
        appVersionCopyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopyAppVersion = false
        }
    }

    private func shareDiagnostics() {
        DiagnosticsLogger.shared.record("diagnostics_share_requested")
        guard let url = DiagnosticsLogger.shared.makeShareFile() else { return }
        HapticFeedback.shared.trigger(.emphasized)
        diagnosticsShareURLForCleanup = url
        diagnosticsShareFile = DiagnosticsShareFile(url: url)
    }

    private func removeSharedDiagnosticsFile() {
        guard let url = diagnosticsShareURLForCleanup else { return }
        DiagnosticsLogger.shared.removeShareFile(at: url)
        diagnosticsShareURLForCleanup = nil
        diagnosticsShareFile = nil
    }
}

private struct DiagnosticsShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct DiagnosticsActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
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
