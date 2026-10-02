import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CommonPhraseSettingsView: View {
    @ObservedObject var store: CommonPhraseStore
    var onReturn: () -> Void = {}
    @EnvironmentObject private var localization: LocalizationStore
    @State private var selectedButton: RemoteButton?
    @State private var selectedID: String?
    @State private var search = ""
    @State private var draggedPhraseID: String?
    @State private var text = ""
    @State private var shortLabel = ""
    @State private var englishText = ""
    @State private var englishLabel = ""
    @State private var messageKey: String?
    @State private var fileOperation: UInt64 = 0
    @State private var selectionOperation: UInt64 = 0
    private var english: Bool { localization.locale.language.languageCode?.identifier == "en" }
    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !shortLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.isAvailable
    }
    private var filteredPhrases: [CommonPhrase] {
        store.archive.entries.filter {
            search.isEmpty || $0.label(english: english).localizedCaseInsensitiveContains(search)
                || $0.text(english: english).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Button(action: onReturn) {
                    Text(localization.text("common_phrases.return_to_buttons"))
                        .font(.system(size: 16, weight: .medium))
                        .frame(minWidth: 72, minHeight: 44)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityIdentifier("common-phrases-return")
                Text(localization.text("common_phrases.adjust"))
                    .font(.system(size: 25, weight: .semibold))
            }.padding(22)
            GeometryReader { geometry in
                let available = geometry.size.width - 44 - 28
                let padWidth = min(300, max(230, available * 0.34))
                let libraryWidth = min(255, max(180, available * 0.29))
                HStack(alignment: .top, spacing: 14) {
                    assignmentColumn(diameter: padWidth - 28).frame(width: padWidth)
                    libraryColumn.frame(width: libraryWidth)
                    editorColumn.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 22).padding(.bottom, 22)
            }
        }
        .font(.system(size: 13)).textFieldStyle(.roundedBorder)
        .onAppear {
            if selectedID == nil { select(store.archive.entries.first) }
            AppLogger.shared.write("COMMON_PHRASES EDITOR phase=opened result=visible")
        }
        .onDisappear { AppLogger.shared.write("COMMON_PHRASES EDITOR phase=closed result=hidden") }
    }

    private func assignmentColumn(diameter: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localization.text("common_phrases.assign_hint")).font(.system(size: 16, weight: .semibold))
            Text(localization.text("common_phrases.position_first"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            CommonPhrasePad(store: store, diameter: diameter, selectedButton: selectedButton, onSelect: selectPosition)
                .padding(.vertical, 10)
            Text(localization.text(selectedButton == nil ? "common_phrases.choose_position" : "common_phrases.choose_phrase"))
                .foregroundStyle(selectedButton == nil ? Color.secondary : Color.accentColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(localization.text("common_phrases.assign_only"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(14).frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
    }

    private var libraryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localization.text("common_phrases.library")).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 0)
                Button {
                    selectedButton = nil
                    select(nil)
                } label: { Label(localization.text("common_phrases.add"), systemImage: "plus") }
                .controlSize(.large)
                .help(localization.text("common_phrases.add"))
                .accessibilityLabel(localization.text("common_phrases.add"))
                .accessibilityIdentifier("common-phrases-add")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(localization.text("common_phrases.search"), text: $search)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("common-phrases-search")
            }
            .padding(10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredPhrases) { phrase in
                        Button { choosePhrase(phrase) } label: {
                            HStack(spacing: 6) {
                                VStack(spacing: 3) {
                                    ForEach(0..<3) { _ in
                                        HStack(spacing: 3) {
                                            Circle().frame(width: 2, height: 2)
                                            Circle().frame(width: 2, height: 2)
                                        }
                                    }
                                }
                                    .frame(width: 10).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(phrase.label(english: english))
                                    .foregroundStyle(selectedID == phrase.id ? Color.blue : Color.primary)
                                    .fontWeight(selectedID == phrase.id ? .semibold : .regular)
                                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 4) {
                                    ForEach(CommonPhraseStore.buttons.filter { store.phrase(for: $0)?.id == phrase.id }) { button in
                                        if button == .ok {
                                            Text("OK").font(.system(size: 12, weight: .medium))
                                        } else {
                                            Image(systemName: symbol(for: button)).font(.system(size: 12, weight: .medium))
                                        }
                                    }
                                }
                                .padding(.horizontal, 7)
                                .frame(minHeight: 24)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.10)))
                                .foregroundStyle(.primary)
                                .opacity(CommonPhraseStore.buttons.contains { store.phrase(for: $0)?.id == phrase.id } ? 1 : 0)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            .background(selectedID == phrase.id ? Color.blue.opacity(0.18) : Color(nsColor: .textBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(phrase.text(english: english))
                        .accessibilityIdentifier("common-phrases-entry-\(phrase.id)")
                        .onDrag {
                            draggedPhraseID = phrase.id
                            let provider = NSItemProvider()
                            provider.registerDataRepresentation(forTypeIdentifier: "app.sayall.common-phrase", visibility: .ownProcess) { completion in
                                completion(Data(phrase.id.utf8), nil)
                                return nil
                            }
                            return provider
                        }
                        .onDrop(of: ["app.sayall.common-phrase"], isTargeted: nil) { _ in
                            defer { draggedPhraseID = nil }
                            guard let draggedPhraseID,
                                  let source = store.archive.entries.firstIndex(where: { $0.id == draggedPhraseID }),
                                  let target = store.archive.entries.firstIndex(where: { $0.id == phrase.id }) else { return false }
                            return perform { try store.move(draggedPhraseID, by: target - source) }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
            if let selectedID {
                HStack {
                    Button { perform { try store.move(selectedID, by: -1) } } label: { Image(systemName: "arrow.up") }
                        .help(localization.text("common_phrases.move_up")).accessibilityLabel(localization.text("common_phrases.move_up"))
                    Button { perform { try store.move(selectedID, by: 1) } } label: { Image(systemName: "arrow.down") }
                        .help(localization.text("common_phrases.move_down")).accessibilityLabel(localization.text("common_phrases.move_down"))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { backupButtons }
                VStack(alignment: .leading, spacing: 8) { backupButtons }
            }.font(.system(size: 12))
            Text(localization.text("common_phrases.import_hint"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14).frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
    }

    private var editorColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(localization.text("common_phrases.editor")).font(.system(size: 16, weight: .semibold))
                if store.loadFailed {
                    Text(localization.text("common_phrases.error.resource_unavailable")).foregroundStyle(.red)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.text("common_phrases.short_label")).foregroundStyle(.secondary)
                    TextField("", text: $shortLabel)
                        .textFieldStyle(.plain).padding(10).frame(minHeight: 36)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                        .accessibilityLabel(localization.text("common_phrases.short_label"))
                        .accessibilityIdentifier("common-phrases-label")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.text("common_phrases.full_text")).foregroundStyle(.secondary)
                    TextEditor(text: $text)
                        .scrollContentBackground(.hidden).frame(height: 90).padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                        .accessibilityLabel(localization.text("common_phrases.full_text"))
                        .accessibilityIdentifier("common-phrases-text")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.text("common_phrases.english_label")).foregroundStyle(.secondary)
                    TextField("", text: $englishLabel)
                        .textFieldStyle(.plain).padding(10).frame(minHeight: 36)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                        .accessibilityLabel(localization.text("common_phrases.english_label"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(localization.text("common_phrases.english_text")).foregroundStyle(.secondary)
                    TextEditor(text: $englishText)
                        .scrollContentBackground(.hidden).frame(height: 90).padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
                        .accessibilityLabel(localization.text("common_phrases.english_text"))
                        .accessibilityIdentifier("common-phrases-english-text")
                }
                ViewThatFits(in: .horizontal) {
                    HStack { editButtons }
                    VStack(alignment: .leading) { editButtons }
                }
                Text(localization.text("common_phrases.local_storage"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let messageKey {
                    Text(localization.text(messageKey))
                        .foregroundStyle(messageKey.contains("error") ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.hidden).frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.09)))
    }

    @ViewBuilder private var editButtons: some View {
        Button {
            perform {
                let phrase = CommonPhrase(id: selectedID ?? "user-" + UUID().uuidString,
                    chineseText: text, chineseLabel: shortLabel, englishText: englishText, englishLabel: englishLabel)
                selectedID = try store.save(phrase, replacing: selectedID)
            }
        } label: {
            Text(localization.text("common_phrases.save"))
                .padding(.horizontal, 18).padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .opacity(canSave ? 1 : 0.45)
        .disabled(!canSave)
        .accessibilityIdentifier("common-phrases-save")
        if let selectedID {
            Button {
                perform { try store.delete(selectedID); select(nil) }
            } label: {
                Label(localization.text("common_phrases.delete"), systemImage: "trash")
                    .padding(.horizontal, 10).padding(.vertical, 9)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private var backupButtons: some View {
        Button(localization.text("common_phrases.import")) { importPhrases() }
            .controlSize(.large).fixedSize()
        Button(localization.text("common_phrases.export")) { exportPhrases() }
            .controlSize(.large).fixedSize().disabled(!store.isAvailable)
    }

    private func symbol(for button: RemoteButton) -> String {
        switch button {
        case .up: "chevron.up"
        case .down: "chevron.down"
        case .left: "chevron.left"
        default: "chevron.right"
        }
    }

    private func selectPosition(_ button: RemoteButton) {
        selectionOperation &+= 1
        AppLogger.shared.write("COMMON_PHRASES POSITION operation_id=\(selectionOperation) phase=requested button=\(button.rawValue)")
        selectedButton = button
        select(store.phrase(for: button))
        AppLogger.shared.write("COMMON_PHRASES POSITION operation_id=\(selectionOperation) phase=completed result=selected button=\(button.rawValue)")
    }

    private func choosePhrase(_ phrase: CommonPhrase) {
        select(phrase)
        guard let selectedButton else { return }
        perform { try store.assign(selectedButton, to: phrase.id) }
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
        let imported = perform {
            try store.importData(Data(contentsOf: url))
            selectedButton = nil
            select(store.archive.entries.first)
        }
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
