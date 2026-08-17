import AppKit
import SwiftUI

private struct TranscriptApplicationSummary: Identifiable {
    let id: String
    let name: String
    let bundleIdentifier: String
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
                    bundleIdentifier: records.first?.bundleIdentifier ?? "",
                    count: records.count
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var activeApplicationKey: String? {
        guard let selectedApplicationKey,
              applications.contains(where: { $0.id == selectedApplicationKey })
        else { return nil }
        return selectedApplicationKey
    }

    private var selectedApplication: TranscriptApplicationSummary? {
        guard let activeApplicationKey else { return nil }
        return applications.first { $0.id == activeApplicationKey }
    }

    private var dayGroups: [TranscriptDayGroup] {
        let records: [TranscriptRecord]
        if let activeApplicationKey {
            records = model.transcriptRecords.filter {
                $0.applicationKey == activeApplicationKey
            }
        } else {
            records = model.transcriptRecords
        }
        return Dictionary(grouping: records, by: \.localDateKey)
            .map { key, records in
                TranscriptDayGroup(
                    id: key,
                    records: records.sorted { $0.endedAt > $1.endedAt }
                )
            }
            .sorted {
                ($0.records.first?.endedAt ?? .distantPast) >
                    ($1.records.first?.endedAt ?? .distantPast)
            }
    }

    var body: some View {
        VStack(spacing: 14) {
            if model.transcriptRecords.isEmpty {
                GlassPanel {
                    emptyState
                }
            } else {
                historyContent
            }

            deleteAllRow
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
        HStack(alignment: .top, spacing: 14) {
            GlassPanel {
                VStack(alignment: .leading, spacing: 12) {
                    Text("statistics.transcripts.applications")
                        .font(.system(size: 14, weight: .semibold))
                    Divider()
                    VStack(spacing: 6) {
                        allApplicationsButton
                        ForEach(applications) { application in
                            applicationButton(application)
                        }
                    }
                }
            }
            .frame(width: 250, alignment: .topLeading)

            GlassPanel {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        if let selectedApplication {
                            applicationIcon(selectedApplication, size: 44)
                        } else {
                            Image(systemName: "square.grid.2x2.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 44, height: 44)
                                .background(
                                    Color.accentColor.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                )
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedApplication?.name
                                ?? localization.text("statistics.transcripts.all_applications"))
                                .font(.system(size: 18, weight: .semibold))
                                .lineLimit(1)
                            Text(localizedEntryCount(
                                selectedApplication?.count ?? model.transcriptRecords.count
                            ))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 16)

                        if let selectedApplication {
                            Button("statistics.transcripts.delete_application", role: .destructive) {
                                deletionRequest = .application(
                                    key: selectedApplication.id,
                                    name: selectedApplication.name
                                )
                            }
                            .font(.system(size: 12, weight: .medium))
                            .buttonStyle(.bordered)
                        }
                    }

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
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var allApplicationsButton: some View {
        Button {
            selectedApplicationKey = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        selectedApplicationKey == nil ? Color.accentColor : Color.secondary
                    )
                    .frame(width: 34, height: 34)
                    .background(
                        Color.accentColor.opacity(selectedApplicationKey == nil ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("statistics.transcripts.all_applications")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(localizedEntryCount(model.transcriptRecords.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            selectedApplicationKey == nil
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .foregroundStyle(selectedApplicationKey == nil ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selectedApplicationKey == nil ? .isSelected : [])
    }

    private func applicationButton(_ application: TranscriptApplicationSummary) -> some View {
        Button {
            selectedApplicationKey = application.id
        } label: {
            HStack(spacing: 10) {
                applicationIcon(application, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(localizedEntryCount(application.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
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
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .foregroundStyle(
            activeApplicationKey == application.id ? Color.accentColor : Color.primary
        )
        .accessibilityAddTraits(activeApplicationKey == application.id ? .isSelected : [])
    }

    private func applicationIcon(
        _ application: TranscriptApplicationSummary,
        size: CGFloat
    ) -> some View {
        applicationIcon(bundleIdentifier: application.bundleIdentifier, size: size)
    }

    private func applicationIcon(
        bundleIdentifier: String,
        size: CGFloat
    ) -> some View {
        Group {
            if let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.18)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var deleteAllRow: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("statistics.transcripts.description")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 18)

            if !model.transcriptRecords.isEmpty {
                Button("statistics.transcripts.delete_all", role: .destructive) {
                    deletionRequest = .all
                }
                .font(.system(size: 12, weight: .medium))
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func transcriptRow(_ record: TranscriptRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(timeText(record))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .leading)

            if activeApplicationKey == nil {
                HStack(spacing: 8) {
                    applicationIcon(bundleIdentifier: record.bundleIdentifier, size: 24)
                    Text(record.applicationName.nilIfBlank
                        ?? localization.text("statistics.transcripts.unknown_application"))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }
                .frame(width: 132, alignment: .leading)
            }

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
        guard let current = selectedApplicationKey else { return }
        guard applications.contains(where: { $0.id == current }) else {
            selectedApplicationKey = nil
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

    private func localizedEntryCount(_ count: Int) -> String {
        String(
            format: localization.text("statistics.transcripts.entry_count"),
            locale: localization.locale,
            localizedCount(count)
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
