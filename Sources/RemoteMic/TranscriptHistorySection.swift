import SwiftUI

private struct TranscriptApplicationSummary: Identifiable {
    let id: String
    let name: String
    let count: Int
}

private struct TranscriptDayGroup: Identifiable {
    let id: String
    let records: [TranscriptRecord]
}

private enum TranscriptDeletionRequest: Identifiable {
    case record(TranscriptRecord)
    case application(key: String, name: String)
    case all

    var id: String {
        switch self {
        case let .record(record): return "record-\(record.id.uuidString)"
        case let .application(key, _): return "application-\(key)"
        case .all: return "all"
        }
    }
}

struct TranscriptHistorySection: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore

    @State private var selectedApplicationKey: String?
    @State private var copiedRecordID: UUID?
    @State private var deletionRequest: TranscriptDeletionRequest?

    private var applications: [TranscriptApplicationSummary] {
        Dictionary(grouping: model.transcriptRecords, by: \.applicationKey)
            .map { key, records in
                TranscriptApplicationSummary(
                    id: key,
                    name: records.first?.applicationName.nilIfBlank
                        ?? localization.text("statistics.transcripts.unknown_application"),
                    count: records.count
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var activeApplicationKey: String? {
        guard let selectedApplicationKey,
              applications.contains(where: { $0.id == selectedApplicationKey })
        else { return applications.first?.id }
        return selectedApplicationKey
    }

    private var selectedApplication: TranscriptApplicationSummary? {
        guard let activeApplicationKey else { return nil }
        return applications.first { $0.id == activeApplicationKey }
    }

    private var dayGroups: [TranscriptDayGroup] {
        guard let activeApplicationKey else { return [] }
        let records = model.transcriptRecords.filter {
            $0.applicationKey == activeApplicationKey
        }
        return Dictionary(grouping: records, by: \.localDateKey)
            .map { key, records in
                TranscriptDayGroup(
                    id: key,
                    records: records.sorted { $0.endedAt > $1.endedAt }
                )
            }
            .sorted { $0.id > $1.id }
    }

    var body: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 16) {
                header

                Divider()

                if model.transcriptRecords.isEmpty {
                    emptyState
                } else {
                    historyContent
                }

                Text("statistics.transcripts.privacy")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            model.refreshTranscriptRecords()
            normalizeSelection()
        }
        .onChange(of: applications.map(\.id)) { _, _ in
            normalizeSelection()
        }
        .alert(item: $deletionRequest, content: deletionAlert)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text("statistics.transcripts.title")
                    .font(.headline)
                Text("statistics.transcripts.description")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            VStack(alignment: .trailing, spacing: 8) {
                Toggle("statistics.transcripts.enable", isOn: $settings.localTranscriptHistoryEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .medium))

                if !model.transcriptRecords.isEmpty {
                    HStack(spacing: 8) {
                        if let selectedApplication {
                            Button("statistics.transcripts.delete_application") {
                                deletionRequest = .application(
                                    key: selectedApplication.id,
                                    name: selectedApplication.name
                                )
                            }
                            .font(.system(size: 12))
                        }

                        Button("statistics.transcripts.delete_all", role: .destructive) {
                            deletionRequest = .all
                        }
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: settings.localTranscriptHistoryEnabled
                ? "text.bubble"
                : "text.bubble.fill")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(settings.localTranscriptHistoryEnabled
                ? "statistics.transcripts.empty"
                : "statistics.transcripts.disabled")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 116)
    }

    private var historyContent: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                ForEach(applications) { application in
                    Button {
                        selectedApplicationKey = application.id
                    } label: {
                        HStack(spacing: 8) {
                            Text(application.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(localizedCount(application.count))
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        activeApplicationKey == application.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .foregroundStyle(
                        activeApplicationKey == application.id ? Color.accentColor : Color.primary
                    )
                    .accessibilityAddTraits(
                        activeApplicationKey == application.id ? .isSelected : []
                    )
                }
            }
            .frame(width: 190, alignment: .topLeading)

            Divider()

            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(dayGroups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(dayTitle(for: group))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)

                        ForEach(Array(group.records.enumerated()), id: \.element.id) {
                            index, record in
                            transcriptRow(record)
                            if index < group.records.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func transcriptRow(_ record: TranscriptRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeText(record))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)

            Text(record.originalTranscript)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                guard model.copyTranscript(record) else { return }
                copiedRecordID = record.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedRecordID == record.id {
                        copiedRecordID = nil
                    }
                }
            } label: {
                Image(systemName: copiedRecordID == record.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(localization.text("statistics.transcripts.copy"))

            Button(role: .destructive) {
                deletionRequest = .record(record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(localization.text("statistics.transcripts.delete_record"))
        }
        .padding(.vertical, 9)
    }

    private func normalizeSelection() {
        guard let current = selectedApplicationKey,
              applications.contains(where: { $0.id == current })
        else {
            selectedApplicationKey = applications.first?.id
            return
        }
    }

    private func deletionAlert(_ request: TranscriptDeletionRequest) -> Alert {
        let titleKey: String
        let message: String
        switch request {
        case .record:
            titleKey = "statistics.transcripts.delete_record_confirm.title"
            message = localization.text("statistics.transcripts.delete_record_confirm.message")
        case let .application(_, name):
            titleKey = "statistics.transcripts.delete_application_confirm.title"
            message = String(
                format: localization.text("statistics.transcripts.delete_application_confirm.message"),
                locale: localization.locale,
                name
            )
        case .all:
            titleKey = "statistics.transcripts.delete_all_confirm.title"
            message = localization.text("statistics.transcripts.delete_all_confirm.message")
        }
        return Alert(
            title: Text(localization.text(titleKey)),
            message: Text(message),
            primaryButton: .destructive(Text(localization.text("common.action.delete"))) {
                performDeletion(request)
            },
            secondaryButton: .cancel(Text(localization.text("common.action.cancel")))
        )
    }

    private func performDeletion(_ request: TranscriptDeletionRequest) {
        switch request {
        case let .record(record):
            model.deleteTranscriptRecord(record)
        case let .application(key, _):
            model.deleteTranscriptApplication(applicationKey: key)
        case .all:
            model.deleteAllTranscripts()
        }
    }

    private func dayTitle(for group: TranscriptDayGroup) -> String {
        guard let record = group.records.first,
              let timeZone = TimeZone(identifier: record.timeZoneIdentifier)
        else { return group.id }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = Calendar(identifier: .gregorian)
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: group.id) else { return group.id }
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func timeText(_ record: TranscriptRecord) -> String {
        let formatter = DateFormatter()
        formatter.locale = localization.locale
        formatter.timeZone = TimeZone(identifier: record.timeZoneIdentifier)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: record.endedAt)
    }

    private func localizedCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = localization.locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
