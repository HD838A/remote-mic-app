import AppKit
import SwiftUI

private struct TranscriptApplicationSummary: Identifiable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let count: Int
    let latestEndedAt: Date
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
    @State private var isApplicationSwitcherExpanded = false
    @State private var expandedDayKeys: Set<String> = []
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
                    count: records.count,
                    latestEndedAt: records.map(\.endedAt).max() ?? .distantPast
                )
            }
            .sorted {
                if $0.latestEndedAt == $1.latestEndedAt {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.latestEndedAt > $1.latestEndedAt
            }
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

            TranscriptAgentAccessSection()
            deleteAllRow
        }
        .onAppear {
            model.refreshTranscriptRecords()
            normalizeSelection()
            normalizeExpandedDays()
        }
        .onChange(of: applications.map(\.id)) { _ in
            normalizeSelection()
        }
        .onChange(of: activeApplicationKey) { _ in
            resetExpandedDays()
        }
        .onChange(of: dayGroups.map(\.id)) { _ in
            normalizeExpandedDays()
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedApplication?.name
                        ?? localization.text("statistics.transcripts.all_records"))
                        .font(.system(size: 22, weight: .semibold))
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
                    .buttonStyle(.borderless)
                    .fixedSize()
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isApplicationSwitcherExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(isApplicationSwitcherExpanded
                            ? "statistics.transcripts.collapse_applications"
                            : "statistics.transcripts.expand_applications")
                        Image(systemName: isApplicationSwitcherExpanded
                            ? "chevron.up"
                            : "chevron.down")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .fixedSize()
            }

            applicationSwitcher

            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(dayGroups) { group in
                    dayGroupView(group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var applicationSwitcher: some View {
        GlassPanel {
            if isApplicationSwitcherExpanded {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 142, maximum: 220),
                            spacing: 8,
                            alignment: .leading
                        )
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    allApplicationsButton(fillsAvailableWidth: true)
                    ForEach(applications) { application in
                        applicationButton(application, fillsAvailableWidth: true)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    allApplicationsButton(fillsAvailableWidth: false)

                    Divider()
                        .frame(height: 42)

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 8) {
                                ForEach(applications) { application in
                                    applicationButton(
                                        application,
                                        fillsAvailableWidth: false
                                    )
                                    .id(application.id)
                                }
                            }
                        }
                        .onChange(of: activeApplicationKey) { applicationKey in
                            guard let applicationKey else { return }
                            withAnimation(.easeInOut(duration: 0.18)) {
                                proxy.scrollTo(applicationKey, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    private func allApplicationsButton(fillsAvailableWidth: Bool) -> some View {
        Button {
            selectedApplicationKey = nil
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        selectedApplicationKey == nil ? Color.accentColor : Color.secondary
                    )
                    .frame(width: 32, height: 32)
                    .background(
                        Color.accentColor.opacity(selectedApplicationKey == nil ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("statistics.transcripts.all_applications")
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(localizedCount(model.transcriptRecords.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: fillsAvailableWidth ? nil : 166)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
        .background(
            selectedApplicationKey == nil
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .foregroundStyle(selectedApplicationKey == nil ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selectedApplicationKey == nil ? .isSelected : [])
        .accessibilityValue(localizedEntryCount(model.transcriptRecords.count))
    }

    private func applicationButton(
        _ application: TranscriptApplicationSummary,
        fillsAvailableWidth: Bool
    ) -> some View {
        Button {
            selectedApplicationKey = application.id
        } label: {
            HStack(spacing: 9) {
                applicationIcon(application, size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(localizedCount(application.count))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: fillsAvailableWidth ? nil : 158)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
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
        .accessibilityValue(localizedEntryCount(application.count))
    }

    private func dayGroupView(_ group: TranscriptDayGroup) -> some View {
        let isExpanded = expandedDayKeys.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggleDay(group.id)
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14)
                    Text(dayTitle(for: group))
                        .font(.system(size: 14, weight: .semibold))
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(localizedEntryCount(group.records.count))
                        .font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 12)
                }
                .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(localizedEntryCount(group.records.count))

            Divider()

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(group.records.enumerated()), id: \.element.id) {
                        index, record in
                        timelineRecordRow(
                            record,
                            isLast: index == group.records.count - 1
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func timelineRecordRow(_ record: TranscriptRecord, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.78))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .padding(.top, 17)
            }
            .frame(width: 28)

            VStack(spacing: 0) {
                transcriptRow(record)
                if !isLast {
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                .frame(width: 54, alignment: .leading)

            HStack(spacing: 8) {
                applicationIcon(bundleIdentifier: record.bundleIdentifier, size: 24)
                Text(record.applicationName.nilIfBlank
                    ?? localization.text("statistics.transcripts.unknown_application"))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 126, alignment: .leading)

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

    private func normalizeExpandedDays() {
        let validKeys = Set(dayGroups.map(\.id))
        expandedDayKeys.formIntersection(validKeys)
        if expandedDayKeys.isEmpty, let newestDayKey = dayGroups.first?.id {
            expandedDayKeys.insert(newestDayKey)
        }
    }

    private func resetExpandedDays() {
        expandedDayKeys = Set(dayGroups.prefix(1).map(\.id))
    }

    private func toggleDay(_ dayKey: String) {
        if expandedDayKeys.contains(dayKey) {
            expandedDayKeys.remove(dayKey)
        } else {
            expandedDayKeys.insert(dayKey)
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
