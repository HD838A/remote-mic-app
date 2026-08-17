import SayAllMCPKit
import SwiftUI

struct TranscriptAgentAccessSection: View {
    @StateObject private var model = TranscriptAgentAccessModel()
    @EnvironmentObject private var localization: LocalizationStore

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("statistics.transcripts.agent_access.title")
                            .font(.system(size: 15, weight: .semibold))
                        Text("statistics.transcripts.agent_access.description")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 16)
                    Toggle(
                        "statistics.transcripts.agent_access.enable",
                        isOn: Binding(
                            get: { model.isEnabled },
                            set: model.setEnabled
                        )
                    )
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize()
                }

                Text("statistics.transcripts.agent_access.privacy")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isEnabled {
                    Divider()
                    authorizationCreator

                    if let configuration = model.generatedConfiguration {
                        generatedConfiguration(configuration)
                    }
                }

                Divider()
                authorizationList

                if let error = model.error {
                    Text(errorText(error))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear(perform: model.refresh)
    }

    private var authorizationCreator: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("statistics.transcripts.agent_access.add_client")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                TextField(
                    "statistics.transcripts.agent_access.client_name_placeholder",
                    text: $model.clientName
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .onSubmit(model.createAuthorization)

                Button("statistics.transcripts.agent_access.create") {
                    model.createAuthorization()
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 13, weight: .semibold))
            }
            Text("statistics.transcripts.agent_access.configuration_once")
                .font(.system(size: 12))
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
            .font(.system(size: 12, weight: .medium))
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
                .font(.system(size: 13, weight: .semibold))

            if model.authorizations.isEmpty {
                Text("statistics.transcripts.agent_access.no_authorizations")
                    .font(.system(size: 12))
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
                .font(.system(size: 15))
                .foregroundStyle(authorization.revokedAt == nil ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(authorization.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(authorizationDate(authorization.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if authorization.revokedAt == nil {
                Button("statistics.transcripts.agent_access.revoke", role: .destructive) {
                    model.revoke(authorization)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
            } else {
                Text("statistics.transcripts.agent_access.revoked")
                    .font(.system(size: 12, weight: .medium))
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
        }
        return localization.text(key)
    }

    private func authorizationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
