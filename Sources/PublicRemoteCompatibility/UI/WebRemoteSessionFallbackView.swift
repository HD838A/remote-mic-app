import SayAllMacRemoteCore
import SwiftUI

@MainActor
public protocol WebRemoteSessionModel: ObservableObject {
    var webRemoteState: WebRemoteSessionState { get }

    func enableWebRemoteConnection()
    func disableWebRemoteConnection()
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
        localization: WebRemoteSessionLocalization
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.localization = localization
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
