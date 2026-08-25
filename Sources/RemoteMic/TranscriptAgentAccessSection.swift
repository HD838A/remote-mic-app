import SayAllMCPKit
import SwiftUI

struct TranscriptAgentAccessSection: View {
    @StateObject private var model = TranscriptAgentAccessModel()
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        Section {
            LabeledContent {
                Toggle(
                    "statistics.transcripts.agent_access.enable",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: model.setEnabled
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(model.integrationInProgress != nil)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("statistics.transcripts.agent_access.enable")
                        .font(.body.weight(.medium))
                    Text("statistics.transcripts.agent_access.description")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.isEnabled {
                quickConnections
                authorizationCreator

                if let configuration = model.generatedConfiguration {
                    generatedConfiguration(configuration)
                }
            }

            authorizationList

            if let error = model.error {
                Text(errorText(error))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("statistics.transcripts.agent_access.title")
        } footer: {
            Text("statistics.transcripts.agent_access.privacy")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: model.refresh)
    }

    private var quickConnections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("statistics.transcripts.agent_access.quick_connect")
                .font(.body.weight(.semibold))
            Text("statistics.transcripts.agent_access.quick_connect_description")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                ForEach(MCPClientKind.allCases) { client in
                    clientCard(client)
                }
            }
        }
    }

    private func clientCard(_ client: MCPClientKind) -> some View {
        let connected = model.activeAuthorization(for: client) != nil
        let needsReconnect = model.needsReconnect(client)
        let available = model.isAvailable(client)
        let isWorking = model.integrationInProgress == client
        let status = needsReconnect
            ? localization.text("statistics.transcripts.agent_access.path_changed")
            : connected
            ? String(
                format: localization.text(
                    "statistics.transcripts.agent_access.connected"
                ),
                locale: localization.locale,
                client.displayName
            )
            : localization.text(
                available
                    ? "statistics.transcripts.agent_access.ready"
                    : "statistics.transcripts.agent_access.not_installed"
            )

        return HStack(spacing: 10) {
            Group {
                if let icon = model.applicationIcon(client) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: client.fallbackSymbol)
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(client.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(status)
                .font(.callout)
                .foregroundStyle(needsReconnect ? Color.orange : (connected ? Color.green : .secondary))
            }

            Spacer(minLength: 6)

            if isWorking {
                ProgressView()
                    .controlSize(.small)
            } else if connected {
                Button("statistics.transcripts.agent_access.remove_connection", role: .destructive) {
                    model.removeConnection(client)
                }
                .buttonStyle(.bordered)
                .font(.callout.weight(.medium))
            } else {
                Button("statistics.transcripts.agent_access.connect") {
                    model.connect(client)
                }
                .buttonStyle(.borderedProminent)
                .font(.callout.weight(.medium))
                .disabled(!available || model.integrationInProgress != nil)
            }
        }
        .padding(10)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var authorizationCreator: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("statistics.transcripts.agent_access.manual_setup")
                .font(.body.weight(.semibold))
            Text("statistics.transcripts.agent_access.manual_setup_description")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                TextField(
                    "statistics.transcripts.agent_access.client_name_placeholder",
                    text: $model.clientName
                )
                .textFieldStyle(.roundedBorder)
                .font(.body)
                .onSubmit(model.createAuthorization)

                Button("statistics.transcripts.agent_access.create") {
                    model.createAuthorization()
                }
                .buttonStyle(.borderedProminent)
                .font(.callout.weight(.medium))
                .disabled(model.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func generatedConfiguration(
        _ configuration: SayAllMCPIntegrationConfig
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .foregroundStyle(Color.accentColor)
                Text(
                    String(
                        format: localization.text(
                            "statistics.transcripts.agent_access.configuration_ready"
                        ),
                        locale: localization.locale,
                        configuration.authorization.displayName
                    )
                )
                .font(.body.weight(.semibold))
            }
            Text("statistics.transcripts.agent_access.configuration_once")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    model.copyStandardConfiguration()
                } label: {
                    Label(
                        model.copiedConfiguration == .standardJSON
                            ? "statistics.transcripts.agent_access.copied"
                            : "statistics.transcripts.agent_access.copy_standard",
                        systemImage: model.copiedConfiguration == .standardJSON
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)

                Button {
                    model.copyCodexConfiguration()
                } label: {
                    Label(
                        model.copiedConfiguration == .codexTOML
                            ? "statistics.transcripts.agent_access.copied"
                            : "statistics.transcripts.agent_access.copy_codex",
                        systemImage: model.copiedConfiguration == .codexTOML
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
                .buttonStyle(.bordered)
            }
            .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(
            Color.accentColor.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var authorizationList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("statistics.transcripts.agent_access.authorizations")
                .font(.body.weight(.semibold))

            if model.authorizations.isEmpty {
                Text("statistics.transcripts.agent_access.no_authorizations")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.authorizations) { authorization in
                    authorizationRow(authorization)
                    if authorization.id != model.authorizations.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func authorizationRow(_ authorization: SayAllMCPAuthorizationRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: authorization.revokedAt == nil ? "cpu" : "cpu.fill")
                .font(.body)
                .foregroundStyle(authorization.revokedAt == nil ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(authorization.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(authorizationDate(authorization.createdAt))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.needsReconnect(authorization) {
                    Text("statistics.transcripts.agent_access.path_changed")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if authorization.revokedAt == nil {
                Button("statistics.transcripts.agent_access.revoke", role: .destructive) {
                    model.revoke(authorization)
                }
                .buttonStyle(.borderless)
                .font(.callout.weight(.medium))
            } else {
                Text("statistics.transcripts.agent_access.revoked")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func errorText(_ error: TranscriptAgentAccessError) -> String {
        let key: String
        switch error {
        case .loadFailed:
            key = "statistics.transcripts.agent_access.error.load"
        case .updateFailed:
            key = "statistics.transcripts.agent_access.error.update"
        case .invalidClientName:
            key = "statistics.transcripts.agent_access.error.name"
        case .authorizationFailed:
            key = "statistics.transcripts.agent_access.error.create"
        case .revokeFailed:
            key = "statistics.transcripts.agent_access.error.revoke"
        case .helperMissing:
            key = "statistics.transcripts.agent_access.error.helper"
        case .clientUnavailable:
            key = "statistics.transcripts.agent_access.error.client_unavailable"
        case .clientCommandUnavailable:
            key = "statistics.transcripts.agent_access.error.client_command_unavailable"
        case .configurationConflict:
            key = "statistics.transcripts.agent_access.error.configuration_conflict"
        case .invalidClientConfiguration:
            key = "statistics.transcripts.agent_access.error.invalid_client_configuration"
        case .unsafeClientConfiguration:
            key = "statistics.transcripts.agent_access.error.unsafe_client_configuration"
        case .clientConfigurationWriteFailed:
            key = "statistics.transcripts.agent_access.error.client_configuration_write"
        case .clientInstallationRejected:
            key = "statistics.transcripts.agent_access.error.client_installation_rejected"
        case .integrationFailed:
            key = "statistics.transcripts.agent_access.error.integration"
        case .configurationRemovalFailed:
            key = "statistics.transcripts.agent_access.error.remove_configuration"
        case .duplicateClient:
            key = "statistics.transcripts.agent_access.error.duplicate_client"
        }
        let text = localization.text(key)
        if let client = model.failedClient {
            return String(
                format: text,
                locale: localization.locale,
                client.displayName
            )
        }
        return text
    }

    private func authorizationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
