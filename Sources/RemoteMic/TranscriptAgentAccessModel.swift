import AppKit
import Combine
import Foundation
import SayAllMCPKit

enum TranscriptAgentAccessError: Equatable {
    case loadFailed
    case updateFailed
    case invalidClientName
    case authorizationFailed
    case revokeFailed
    case helperMissing
}

@MainActor
final class TranscriptAgentAccessModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var authorizations: [SayAllMCPAuthorizationRecord] = []
    @Published var clientName = ""
    @Published private(set) var generatedConfiguration: SayAllMCPIntegrationConfig?
    @Published private(set) var error: TranscriptAgentAccessError?
    @Published private(set) var copiedConfiguration: ConfigurationKind?

    enum ConfigurationKind {
        case standardJSON
        case codexTOML
    }

    private let authorizationStore: SayAllMCPAuthorizationStore
    private let helperExecutableURL: () -> URL

    init(
        authorizationStore: SayAllMCPAuthorizationStore = SayAllMCPAuthorizationStore(),
        helperExecutableURL: @escaping () -> URL = {
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("SayAllMCP", isDirectory: false)
        }
    ) {
        self.authorizationStore = authorizationStore
        self.helperExecutableURL = helperExecutableURL
    }

    func refresh() {
        do {
            isEnabled = try authorizationStore.isEnabled()
            authorizations = try authorizationStore.listAuthorizations()
            error = nil
        } catch {
            self.error = .loadFailed
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try authorizationStore.setEnabled(enabled)
            isEnabled = enabled
            generatedConfiguration = nil
            copiedConfiguration = nil
            error = nil
        } catch {
            if let restoredValue = try? authorizationStore.isEnabled() {
                isEnabled = restoredValue
            }
            self.error = .updateFailed
        }
    }

    func createAuthorization() {
        let normalizedName = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 100 else {
            error = .invalidClientName
            return
        }
        let helperURL = helperExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            error = .helperMissing
            return
        }
        do {
            let authorization = try authorizationStore.createAuthorization(
                displayName: normalizedName
            )
            generatedConfiguration = try SayAllMCPIntegrationConfig(
                authorization: authorization,
                helperExecutableURL: helperURL
            )
            clientName = ""
            authorizations = try authorizationStore.listAuthorizations()
            copiedConfiguration = nil
            error = nil
        } catch {
            self.error = .authorizationFailed
        }
    }

    func revoke(_ authorization: SayAllMCPAuthorizationRecord) {
        do {
            try authorizationStore.revokeAuthorization(clientId: authorization.clientId)
            authorizations = try authorizationStore.listAuthorizations()
            if generatedConfiguration?.authorization.clientId == authorization.clientId {
                generatedConfiguration = nil
            }
            error = nil
        } catch {
            self.error = .revokeFailed
        }
    }

    func copyStandardConfiguration() {
        guard let text = generatedConfiguration?.standardJSON else { return }
        copy(text, kind: .standardJSON)
    }

    func copyCodexConfiguration() {
        guard let text = generatedConfiguration?.codexTOML else { return }
        copy(text, kind: .codexTOML)
    }

    private func copy(_ text: String, kind: ConfigurationKind) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedConfiguration = kind
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.copiedConfiguration == kind {
                self?.copiedConfiguration = nil
            }
        }
    }
}
