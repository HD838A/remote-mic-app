import AppKit
import SwiftUI

enum QuickPhraseGridNavigation {
    static func destination(
        from currentIndex: Int,
        button: RemoteButton,
        itemCount: Int
    ) -> Int {
        guard itemCount > 0 else { return 0 }
        let current = min(max(0, currentIndex), itemCount - 1)
        switch button {
        case .left:
            return max(0, current - 1)
        case .right:
            return min(itemCount - 1, current + 1)
        case .up:
            return max(0, current - 2)
        case .down:
            return min(itemCount - 1, current + 2)
        default:
            return current
        }
    }
}

enum QuickPhrasePaster {
    typealias KeyStatePoster = (CGKeyCode, Bool, CGEventFlags) -> Bool
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private struct SnapshotItem {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    @discardableResult
    static func paste(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        keyStatePoster: KeyStatePoster = KeyboardInjector.postKeyState,
        scheduler: @escaping Scheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) -> Bool {
        guard !text.isEmpty else { return false }
        let snapshot = snapshot(of: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            restore(snapshot, to: pasteboard)
            return false
        }
        let ownedChangeCount = pasteboard.changeCount
        let pressed = keyStatePoster(9, true, .maskCommand)
        let released = keyStatePoster(9, false, .maskCommand)
        guard pressed && released else {
            if pasteboard.changeCount == ownedChangeCount {
                restore(snapshot, to: pasteboard)
            }
            return false
        }
        scheduler(0.35) {
            guard pasteboard.changeCount == ownedChangeCount else { return }
            restore(snapshot, to: pasteboard)
        }
        return true
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [SnapshotItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            SnapshotItem(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    private static func restore(_ snapshot: [SnapshotItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        let items = snapshot.map { snapshotItem in
            let item = NSPasteboardItem()
            snapshotItem.values.forEach { type, data in
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

@MainActor
final class QuickPhrasePaletteWindowController {
    private let windowController: NSWindowController

    init(
        model: BridgeAppModel,
        settings: AppSettings,
        localization: LocalizationStore
    ) {
        let rootView = QuickPhrasePaletteView(model: model, settings: settings)
            .environmentObject(localization)
        let hostingController = NSHostingController(rootView: rootView)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 450),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hostingController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        windowController = NSWindowController(window: panel)
    }

    func show() {
        guard let panel = windowController.window else { return }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2 + 48
            ))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        windowController.window?.orderOut(nil)
    }
}

private struct QuickPhrasePaletteView: View {
    @ObservedObject var model: BridgeAppModel
    @ObservedObject var settings: AppSettings
    @EnvironmentObject private var localization: LocalizationStore

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 42, height: 42)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("quick_phrases.palette.title")
                        .font(.system(size: 20, weight: .semibold))
                    Text("quick_phrases.palette.subtitle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            if settings.quickPhrases.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("quick_phrases.palette.empty")
                        .font(.system(size: 14, weight: .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(settings.quickPhrases.enumerated()), id: \.element.id) { index, phrase in
                                phraseCard(phrase, index: index)
                                    .id(phrase.id)
                            }
                        }
                    }
                    .onChange(of: model.quickPhrasePaletteSelectionIndex) { index in
                        guard settings.quickPhrases.indices.contains(index) else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(settings.quickPhrases[index].id, anchor: .center)
                        }
                    }
                }
            }

            HStack(spacing: 16) {
                Label("quick_phrases.palette.navigate_hint", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                Label("quick_phrases.palette.insert_hint", systemImage: "return")
                Label("quick_phrases.palette.close_hint", systemImage: "escape")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 660, height: 450)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func phraseCard(_ phrase: QuickPhrase, index: Int) -> some View {
        let isSelected = index == model.quickPhrasePaletteSelectionIndex
        return HStack(alignment: .top, spacing: 12) {
            Text(String(index + 1))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 28, height: 28)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(phrase.title.isEmpty ? localization.text("quick_phrases.untitled") : phrase.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(phrase.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.85) : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
    }
}
