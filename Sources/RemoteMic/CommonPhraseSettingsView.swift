import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CommonPhraseSettingsView: View {
    @ObservedObject var store: CommonPhraseStore
    @EnvironmentObject private var localization: LocalizationStore
    @State private var selectedID: String?
    @State private var text = ""
    @State private var shortLabel = ""
    @State private var englishText = ""
    @State private var englishLabel = ""
    @State private var messageKey: String?
    @State private var fileOperation: UInt64 = 0
    private var english: Bool { localization.locale.language.languageCode?.identifier == "en" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(localization.text("common_phrases.title")).font(.system(size: 22, weight: .semibold))
                    .help(localization.text("common_phrases.settings_hint"))
            }.padding(22)
            Divider()
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.loadFailed {
                        Text(localization.text("common_phrases.error.resource_unavailable")).foregroundStyle(.red)
                    }
                    Text(localization.text("common_phrases.assign_hint")).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 115))], alignment: .leading) {
                        ForEach(CommonPhraseStore.buttons) { button in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(button == .ok ? "OK" : localization.text("common_phrases.key.\(button.rawValue)"))
                                    .fontWeight(.semibold)
                                Text(store.phrase(for: button)?.label(english: english) ?? localization.text("common_phrases.unassigned"))
                                    .lineLimit(2).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                        }
                    }
                    Divider()
                    HStack {
                        Button(localization.text("common_phrases.add")) {
                            select(nil)
                            proxy.scrollTo("phrase-editor", anchor: .top)
                        }
                        Spacer()
                        Button(localization.text("common_phrases.import")) { importPhrases() }
                        Button(localization.text("common_phrases.export")) { exportPhrases() }.disabled(!store.isAvailable)
                    }
                    ForEach(store.archive.entries) { phrase in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                select(phrase)
                                proxy.scrollTo("phrase-editor", anchor: .top)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(phrase.label(english: english)).fontWeight(.medium)
                                    Text(phrase.text(english: english)).foregroundStyle(.secondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { perform { try store.move(phrase.id, by: -1) } } label: { Image(systemName: "arrow.up") }
                                .help(localization.text("common_phrases.move_up"))
                            Button { perform { try store.move(phrase.id, by: 1) } } label: { Image(systemName: "arrow.down") }
                                .help(localization.text("common_phrases.move_down"))
                        }.padding(10)
                            .background(selectedID == phrase.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    Text(localization.text(selectedID == nil ? "common_phrases.add" : "common_phrases.edit"))
                        .fontWeight(.semibold).id("phrase-editor")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.text("common_phrases.short_label")).foregroundStyle(.secondary)
                        TextField(localization.text("common_phrases.short_label"), text: $shortLabel)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.text("common_phrases.full_text")).foregroundStyle(.secondary)
                        TextField(localization.text("common_phrases.full_text"), text: $text, axis: .vertical).lineLimit(2...5)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.text("common_phrases.english_label")).foregroundStyle(.secondary)
                        TextField(localization.text("common_phrases.english_label"), text: $englishLabel)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(localization.text("common_phrases.english_text")).foregroundStyle(.secondary)
                        TextField(localization.text("common_phrases.english_text"), text: $englishText, axis: .vertical).lineLimit(2...5)
                    }
                    HStack {
                        Button(localization.text("common_phrases.save")) {
                            perform {
                                let phrase = CommonPhrase(id: selectedID ?? "user-" + UUID().uuidString,
                                    chineseText: text, chineseLabel: shortLabel, englishText: englishText, englishLabel: englishLabel)
                                selectedID = try store.save(phrase, replacing: selectedID)
                            }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shortLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.isAvailable)
                        if let selectedID {
                            Button(localization.text("common_phrases.delete")) {
                                perform { try store.delete(selectedID); select(nil) }
                            }
                        }
                    }
                    if let selectedID {
                        Text(localization.text("common_phrases.assign_selected")).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack { assignmentButtons(selectedID) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))]) { assignmentButtons(selectedID) }
                        }
                    }
                    if let messageKey {
                        Text(localization.text(messageKey)).foregroundStyle(messageKey.contains("error") ? .red : .secondary)
                    }
                }.font(.system(size: 13)).textFieldStyle(.roundedBorder).padding(22)
              }.scrollIndicators(.hidden)
            }
        }.onAppear { if selectedID == nil, let first = store.archive.entries.first { select(first) } }
    }

    @ViewBuilder private func assignmentButtons(_ id: String) -> some View {
        ForEach(CommonPhraseStore.buttons) { button in
            Button(button == .ok ? "OK" : localization.text("common_phrases.key.\(button.rawValue)")) {
                perform { try store.assign(button, to: id) }
            }
        }
    }

    private func select(_ phrase: CommonPhrase?) {
        selectedID = phrase?.id
        text = phrase?.chineseText ?? ""
        shortLabel = phrase?.chineseLabel ?? ""
        englishText = phrase?.englishText ?? ""
        englishLabel = phrase?.englishLabel ?? ""
        messageKey = nil
    }

    @discardableResult
    private func perform(_ action: () throws -> Void) -> Bool {
        do { try action(); messageKey = "common_phrases.saved"; return true }
        catch {
            messageKey = "common_phrases.error.edit_failed"
            return false
        }
    }

    private func importPhrases() {
        fileOperation &+= 1
        let id = fileOperation
        AppLogger.shared.write("COMMON_PHRASES IMPORT operation_id=\(id) phase=requested")
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            AppLogger.shared.write("COMMON_PHRASES IMPORT operation_id=\(id) phase=completed result=cancelled reason=user_cancelled")
            return
        }
        let imported = perform { try store.importData(Data(contentsOf: url)); select(store.archive.entries.first) }
        AppLogger.shared.write("COMMON_PHRASES IMPORT operation_id=\(id) phase=completed result=\(imported ? "saved" : "failed") reason=\(imported ? "validated" : "invalid_data_or_io")")
    }

    private func exportPhrases() {
        fileOperation &+= 1
        let id = fileOperation
        AppLogger.shared.write("COMMON_PHRASES EXPORT operation_id=\(id) phase=requested")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "common-phrases.json"
        guard panel.runModal() == .OK, let url = panel.url else {
            AppLogger.shared.write("COMMON_PHRASES EXPORT operation_id=\(id) phase=completed result=cancelled reason=user_cancelled")
            return
        }
        let exported = perform { try store.exportData().write(to: url, options: .atomic) }
        AppLogger.shared.write("COMMON_PHRASES EXPORT operation_id=\(id) phase=completed result=\(exported ? "written" : "failed") reason=\(exported ? "file_written" : "io_failed") diagnostic_boundary=file_write_only")
    }
}
