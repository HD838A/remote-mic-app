import AppKit
import Combine
import Foundation
import SayAllMCPKit

enum TranscriptAgentAccessError: Equatable, Sendable {
    case loadFailed
    case updateFailed
    case invalidClientName
    case authorizationFailed
    case revokeFailed
    case helperMissing
    case clientUnavailable
    case configurationConflict
    case integrationFailed
    case configurationRemovalFailed
}

@MainActor
final class TranscriptAgentAccessModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var authorizations: [SayAllMCPAuthorizationRecord] = []
    @Published var clientName = ""
    @Published private(set) var generatedConfiguration: SayAllMCPIntegrationConfig?
    @Published private(set) var error: TranscriptAgentAccessError?
    @Published private(set) var copiedConfiguration: ConfigurationKind?
    @Published private(set) var integrationInProgress: MCPClientKind?

    enum ConfigurationKind {
        case standardJSON
        case codexTOML
    }

    private let authorizationStore: SayAllMCPAuthorizationStore
    private let helperExecutableURL: () -> URL
    private let integrationService: MCPClientIntegrationService

    init(
        authorizationStore: SayAllMCPAuthorizationStore = SayAllMCPAuthorizationStore(),
        integrationService: MCPClientIntegrationService = MCPClientIntegrationService(),
        helperExecutableURL: @escaping () -> URL = {
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("SayAllMCP", isDirectory: false)
        }
    ) {
        self.authorizationStore = authorizationStore
        self.integrationService = integrationService
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

    func isAvailable(_ client: MCPClientKind) -> Bool {
        integrationService.isAvailable(client)
    }

    func applicationIcon(_ client: MCPClientKind) -> NSImage? {
        integrationService.applicationIcon(client)
    }

    func activeAuthorization(for client: MCPClientKind) -> SayAllMCPAuthorizationRecord? {
        authorizations.first {
            $0.integrationIdentifier == client.rawValue && $0.revokedAt == nil
        }
    }

    func connect(_ client: MCPClientKind) {
        guard activeAuthorization(for: client) == nil else { return }
        guard integrationService.isAvailable(client) else {
            error = .clientUnavailable
            return
        }
        let helperURL = helperExecutableURL()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            error = .helperMissing
            return
        }
        integrationInProgress = client
        error = nil
        let authorizationStore = authorizationStore
        let integrationService = integrationService
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: (authorizations: [SayAllMCPAuthorizationRecord], error: TranscriptAgentAccessError?)
            do {
                let authorization = try authorizationStore.createAuthorization(
                    displayName: client.displayName,
                    integrationIdentifier: client.rawValue
                )
                do {
                    let configuration = try SayAllMCPIntegrationConfig(
                        authorization: authorization,
                        helperExecutableURL: helperURL
                    )
                    try integrationService.install(client, configuration: configuration)
                } catch {
                    try? authorizationStore.revokeAuthorization(clientId: authorization.clientId)
                    throw error
                }
                result = (try authorizationStore.listAuthorizations(), nil)
            } catch MCPClientIntegrationError.configurationConflict {
                result = (
                    (try? authorizationStore.listAuthorizations()) ?? [],
                    .configurationConflict
                )
            } catch MCPClientIntegrationError.clientUnavailable {
                result = (
                    (try? authorizationStore.listAuthorizations()) ?? [],
                    .clientUnavailable
                )
            } catch {
                result = (
                    (try? authorizationStore.listAuthorizations()) ?? [],
                    .integrationFailed
                )
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                authorizations = result.authorizations
                if result.error == nil {
                    generatedConfiguration = nil
                    copiedConfiguration = nil
                }
                error = result.error
                integrationInProgress = nil
            }
        }
    }

    func revoke(_ authorization: SayAllMCPAuthorizationRecord) {
        guard let identifier = authorization.integrationIdentifier,
              let client = MCPClientKind(rawValue: identifier),
              authorization.revokedAt == nil
        else {
            revokeManualAuthorization(authorization)
            return
        }

        integrationInProgress = client
        let authorizationStore = authorizationStore
        let integrationService = integrationService
        Task.detached(priority: .userInitiated) { [weak self] in
            var configurationRemovalFailed = false
            do {
                try integrationService.remove(client)
            } catch {
                configurationRemovalFailed = true
            }

            let result: (authorizations: [SayAllMCPAuthorizationRecord], error: TranscriptAgentAccessError?)
            do {
                try authorizationStore.revokeAuthorization(clientId: authorization.clientId)
                result = (
                    try authorizationStore.listAuthorizations(),
                    configurationRemovalFailed ? .configurationRemovalFailed : nil
                )
            } catch {
                result = ((try? authorizationStore.listAuthorizations()) ?? [], .revokeFailed)
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                authorizations = result.authorizations
                if generatedConfiguration?.authorization.clientId == authorization.clientId {
                    generatedConfiguration = nil
                }
                error = result.error
                integrationInProgress = nil
            }
        }
    }

    private func revokeManualAuthorization(_ authorization: SayAllMCPAuthorizationRecord) {
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

    func removeConnection(_ client: MCPClientKind) {
        guard let authorization = activeAuthorization(for: client) else { return }
        revoke(authorization)
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
