import SayAllMacRemoteCore
import SwiftUI

@MainActor
public protocol WebRemoteSessionModel: ObservableObject {
    var webRemoteState: WebRemoteSessionState { get }
    var webRemoteServiceEnvironment: String { get }

    func enableWebRemoteConnection()
    func disableWebRemoteConnection()
}

public extension WebRemoteSessionModel {
    var webRemoteServiceEnvironment: String { "production" }
}

public struct WebRemoteSessionLocalization {
    public let locale: Locale
    private let resolve: (String) -> String

    public init(
        locale: Locale = .current,
        text: @escaping (String) -> String
    ) {
        self.locale = locale
        resolve = text
    }

    public func text(_ key: String) -> String { resolve(key) }
}

public struct WebRemoteSessionView<Model: WebRemoteSessionModel>: View {
    @ObservedObject private var model: Model
    private let localization: WebRemoteSessionLocalization

    public init(
        model: Model,
        localization: WebRemoteSessionLocalization,
        onOpenPlus: (() -> Void)? = nil,
        membershipRequiredView: AnyView? = nil,
        onDiagnostic: @escaping (String) -> Void = { _ in }
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.localization = localization
        _ = onOpenPlus
        _ = membershipRequiredView
        _ = onDiagnostic
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(localization.text("connection.web.unavailable"))
                .font(.headline)
            Text(localization.text("connection.web.unavailable_help"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 440, height: 320)
    }
}

/// 公开构建只保留界面契约；动态小程序码由可选私有模块提供。
public struct WebRemoteMiniProgramCodeView<Model: WebRemoteSessionModel>: View {
    private let localization: WebRemoteSessionLocalization

    public init(
        model: Model,
        localization: WebRemoteSessionLocalization,
        size: CGFloat = 224,
        onDiagnostic: @escaping (String) -> Void = { _ in }
    ) {
        self.localization = localization
    }

    public var body: some View {
        Text(localization.text("connection.web.unavailable_help"))
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
}
