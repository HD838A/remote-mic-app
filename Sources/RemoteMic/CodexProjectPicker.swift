import AppKit
import ApplicationServices
import SQLite3
import SwiftUI

struct CodexProjectPickerItem: Equatable, Identifiable {
    let number: Int
    let title: String

    var id: Int { number }
}
enum CodexProjectPickerModel {
    static let maximumProjectCount = 9

    static func keyCode(for number: Int) -> CGKeyCode? {
        switch number {
        case 1: return 18
        case 2: return 19
        case 3: return 20
        case 4: return 21
        case 5: return 23
        case 6: return 22
        case 7: return 26
        case 8: return 28
        case 9: return 25
        default: return nil
        }
    }

    static func items(
        labels: [String],
        limit: Int = maximumProjectCount,
        fillMissingSlots: Bool = false
    ) -> [CodexProjectPickerItem] {
        let normalized = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var items = Array(normalized.prefix(limit)).enumerated().map { offset, label in
            CodexProjectPickerItem(number: offset + 1, title: label)
        }
        if fillMissingSlots, items.count < limit {
            items += (items.count..<limit).map { offset in
                CodexProjectPickerItem(
                    number: offset + 1,
                    title: "项目\(offset + 1)"
                )
            }
        }
        return items
    }

    static func resolvedLabels(
        accessibilityLabels: [String],
        persistedLabels: [String]
    ) -> [String] {
        let persisted = normalized(persistedLabels)
        return persisted.isEmpty ? normalized(accessibilityLabels) : persisted
    }

    static func movedSelection(
        from index: Int,
        offset: Int,
        count: Int
    ) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + offset, 0), count - 1)
    }

    private static func normalized(_ labels: [String]) -> [String] {
        labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maximumProjectCount)
            .map { $0 }
    }
}

struct CodexSidebarThreadRecord: Equatable {
    let id: String
    let title: String
    let name: String?
    let archived: Bool
    let hasPreview: Bool
    let recencyAtMilliseconds: Int64

    var displayTitle: String {
        let preferred = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preferred.isEmpty { return preferred }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct CodexSidebarState: Equatable {
    let projectOrder: [String]
    let expandedProjectIDs: Set<String>
    let projectIDByThreadID: [String: String]
    let projectlessThreadIDs: Set<String>
}

enum CodexSidebarThreadModel {
    static func labels(
        state: CodexSidebarState,
        threads: [CodexSidebarThreadRecord]
    ) -> [String] {
        let visibleThreads = threads.filter {
            !$0.archived && $0.hasPreview && !$0.displayTitle.isEmpty
        }
        let sortedThreads = visibleThreads.sorted {
            if $0.recencyAtMilliseconds != $1.recencyAtMilliseconds {
                return $0.recencyAtMilliseconds > $1.recencyAtMilliseconds
            }
            return $0.id > $1.id
        }

        var ordered: [CodexSidebarThreadRecord] = []
        var includedThreadIDs: Set<String> = []
        for projectID in state.projectOrder where state.expandedProjectIDs.contains(projectID) {
            for thread in sortedThreads
            where state.projectIDByThreadID[thread.id] == projectID {
                ordered.append(thread)
                includedThreadIDs.insert(thread.id)
            }
        }
        for thread in sortedThreads
        where state.projectlessThreadIDs.contains(thread.id) &&
            !includedThreadIDs.contains(thread.id) {
            ordered.append(thread)
        }

        return ordered
            .prefix(CodexProjectPickerModel.maximumProjectCount)
            .map(\.displayTitle)
    }
}

enum CodexProjectStateReader {
    static func projectLabels(
        at stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json"),
        databaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    ) -> [String] {
        guard let data = try? Data(contentsOf: stateURL) else { return [] }
        return projectLabels(from: data, threads: threadRecords(at: databaseURL))
    }

    static func projectLabels(
        from data: Data,
        threads: [CodexSidebarThreadRecord]
    ) -> [String] {
        guard let state = sidebarState(from: data) else { return [] }
        return CodexSidebarThreadModel.labels(state: state, threads: threads)
    }

    static func sidebarState(from data: Data) -> CodexSidebarState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectOrder = root["project-order"] as? [String]
        else { return nil }

        let atomState = root["electron-persisted-atom-state"] as? [String: Any] ?? [:]
        let expandedProjectIDs = Set(projectOrder.filter { projectID in
            let key = "sidebar-project-expanded-v1-codex:\(projectID)"
            return atomState[key] as? Bool ?? true
        })
        var projectIDByThreadID: [String: String] = [:]
        if let assignments = root["thread-project-assignments"] as? [String: [String: Any]] {
            for (threadID, assignment) in assignments {
                guard let projectID = assignment["projectId"] as? String else { continue }
                projectIDByThreadID[threadID] = projectID
            }
        }
        return CodexSidebarState(
            projectOrder: projectOrder,
            expandedProjectIDs: expandedProjectIDs,
            projectIDByThreadID: projectIDByThreadID,
            projectlessThreadIDs: Set(root["projectless-thread-ids"] as? [String] ?? [])
        )
    }

    private static func threadRecords(at databaseURL: URL) -> [CodexSidebarThreadRecord] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        ) == SQLITE_OK, let database else { return [] }
        defer { sqlite3_close(database) }

        let query = """
        SELECT id, title, name, archived, recency_at_ms
        FROM threads
        WHERE archived = 0 AND preview <> ''
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        var records: [CodexSidebarThreadRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = string(statement, column: 0),
                  let title = string(statement, column: 1)
            else { continue }
            records.append(CodexSidebarThreadRecord(
                id: id,
                title: title,
                name: string(statement, column: 2),
                archived: sqlite3_column_int(statement, 3) != 0,
                hasPreview: true,
                recencyAtMilliseconds: sqlite3_column_int64(statement, 4)
            ))
        }
        return records
    }

    private static func string(
        _ statement: OpaquePointer,
        column: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: text)
    }
}

final class CodexProjectPickerRemoteBridge {
    static let shared = CodexProjectPickerRemoteBridge()

    private let lock = NSLock()
    private var handler: ((RemoteButton) -> Void)?

    func activate(handler: @escaping (RemoteButton) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    func handle(_ button: RemoteButton) -> Bool {
        guard button == .up || button == .down || button == .ok || button == .back else {
            return false
        }
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler else { return false }
        DispatchQueue.main.async {
            handler(button)
        }
        return true
    }
}

private final class CodexProjectPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct CodexProjectPickerView: View {
    let items: [CodexProjectPickerItem]
    let selectedNumber: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("project_picker.title")
                    .font(.system(size: 17, weight: .semibold))
                Text("project_picker.hint")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text("project_picker.empty")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(items) { item in
                        Button {
                            onSelect(item.number)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(item.number)")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .frame(width: 24, height: 24)
                                    .foregroundStyle(
                                        selectedNumber == item.number ? Color.white : Color.accentColor
                                    )
                                    .background(
                                        selectedNumber == item.number
                                            ? Color.accentColor
                                            : Color.accentColor.opacity(0.18),
                                        in: Circle()
                                    )
                                Text(item.title)
                                    .font(.system(size: 13, weight: selectedNumber == item.number ? .semibold : .regular))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text("⌘\(item.number)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .background(
                                selectedNumber == item.number
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay {
                                if selectedNumber == item.number {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 390)
        .background(MacGlassBackground())
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct MacGlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .hudWindow
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

@MainActor
final class CodexProjectPickerController: NSObject, NSWindowDelegate {
    static let shared = CodexProjectPickerController()

    private var panel: CodexProjectPickerPanel?
    private var keyboardMonitor: Any?
    private var projectItems: [CodexProjectPickerItem] = []
    private var selectedIndex = 0

    func show() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier ==
                PresetApplication.codex.bundleIdentifier,
              let processIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else {
            AppLogger.shared.write("CODEX PROJECT PICKER ignored reason=frontmost_app_mismatch")
            return
        }

        let accessibilityLabels = CodexProjectAccessibilityReader.projectLabels(
            for: processIdentifier
        )
        let persistedLabels = CodexProjectStateReader.projectLabels()
        let labels = CodexProjectPickerModel.resolvedLabels(
            accessibilityLabels: accessibilityLabels,
            persistedLabels: persistedLabels
        )
        let labelSource = persistedLabels.isEmpty ? "accessibility" : "codex_state"
        AppLogger.shared.write(
            "CODEX PROJECT PICKER labels source=\(labelSource) " +
                "resolved=\(labels.count) accessibility=\(accessibilityLabels.count) " +
                "persisted=\(persistedLabels.count)"
        )
        present(
            items: CodexProjectPickerModel.items(
                labels: labels,
                fillMissingSlots: persistedLabels.isEmpty
            ),
            processIdentifier: processIdentifier
        )
    }

    private func present(
        items: [CodexProjectPickerItem],
        processIdentifier: pid_t
    ) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
            AppLogger.shared.write("CODEX PROJECT PICKER ignored reason=frontmost_changed")
            return
        }

        dismiss()
        projectItems = items
        selectedIndex = 0

        let panel = CodexProjectPickerPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 390,
                height: panelHeight(for: items)
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // SayAll normally runs as an accessory/menu-bar app. A non-activating
        // panel must remain visible while ChatGPT stays the active app.
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.contentView = makeContentView()
        position(panel, nearProcess: processIdentifier)
        self.panel = panel
        CodexProjectPickerRemoteBridge.shared.activate { [weak self] button in
            self?.handleRemoteButton(button)
        }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            return self.handle(event: event) ? nil : event
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        AppLogger.shared.write("CODEX PROJECT PICKER shown items=\(items.count)")
    }

    private func position(_ panel: NSPanel, nearProcess processIdentifier: pid_t) {
        guard let windowFrame = CodexProjectAccessibilityReader.windowFrame(
            for: processIdentifier
        ) else {
            panel.center()
            return
        }
        let panelSize = panel.frame.size
        let origin = CGPoint(
            x: windowFrame.midX - panelSize.width / 2,
            y: windowFrame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func panelHeight(for items: [CodexProjectPickerItem]) -> CGFloat {
        let rowCount = max(items.count, 1)
        return CGFloat(84 + rowCount * 40)
    }

    private func handle(event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            dismiss()
            return true
        }
        if event.keyCode == 126 {
            moveSelection(by: -1)
            return true
        }
        if event.keyCode == 125 {
            moveSelection(by: 1)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            confirmSelection()
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command,
              let characters = event.charactersIgnoringModifiers,
              let number = Int(characters),
              projectItems.contains(where: { $0.number == number })
        else {
            return false
        }
        select(number: number)
        return true
    }

    private func makeContentView() -> NSView {
        return NSHostingView(
            rootView: CodexProjectPickerView(
                items: projectItems,
                selectedNumber: projectItems.indices.contains(selectedIndex)
                    ? projectItems[selectedIndex].number
                    : nil,
                onSelect: { [weak self] number in
                    self?.select(number: number)
                }
            )
        )
    }

    private func moveSelection(by offset: Int) {
        guard !projectItems.isEmpty else { return }
        selectedIndex = CodexProjectPickerModel.movedSelection(
            from: selectedIndex,
            offset: offset,
            count: projectItems.count
        )
        panel?.contentView = makeContentView()
    }

    private func confirmSelection() {
        guard projectItems.indices.contains(selectedIndex) else { return }
        select(number: projectItems[selectedIndex].number)
    }

    private func handleRemoteButton(_ button: RemoteButton) {
        switch button {
        case .up:
            moveSelection(by: -1)
        case .down:
            moveSelection(by: 1)
        case .ok:
            confirmSelection()
        case .back:
            dismiss()
        default:
            break
        }
    }

    private func select(number: Int) {
        guard projectItems.contains(where: { $0.number == number }) else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) {
            _ = KeyboardInjector.postCodexProjectShortcut(number: number)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else { return }
        CodexProjectPickerRemoteBridge.shared.deactivate()
        removeKeyboardMonitor()
        panel = nil
        projectItems = []
    }

    func dismiss() {
        CodexProjectPickerRemoteBridge.shared.deactivate()
        removeKeyboardMonitor()
        panel?.orderOut(nil)
        panel = nil
        projectItems = []
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
    }
}

private enum CodexProjectAccessibilityReader {
    private static let childAttributes = [
        "AXChildrenInNavigationOrder",
        kAXVisibleChildrenAttribute,
        kAXContentsAttribute,
        kAXChildrenAttribute,
    ]
    private static let maximumTraversalCount = 5_000

    static func projectLabels(for processIdentifier: pid_t) -> [String] {
        let application = AXUIElementCreateApplication(processIdentifier)
        var stack = Array(applicationWindows(application).reversed())
        var visited: [CFHashCode: [AXUIElement]] = [:]
        var labels: [String] = []
        var visitedCount = 0

        while let element = stack.popLast(), visitedCount < maximumTraversalCount {
            visitedCount += 1
            let hash = CFHash(element)
            if visited[hash]?.contains(where: { CFEqual($0, element) }) == true { continue }
            visited[hash, default: []].append(element)

            let label = string(element, attribute: kAXDescriptionAttribute)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if string(element, attribute: kAXRoleAttribute) == kAXButtonRole,
               !label.isEmpty,
               hasProjectAction(element),
               !labels.contains(label) {
                labels.append(label)
            }

            var children: [AXUIElement] = []
            for attribute in childAttributes {
                for child in elements(element, attribute: attribute) {
                    if children.contains(where: { CFEqual($0, child) }) { continue }
                    children.append(child)
                }
            }
            stack.append(contentsOf: children.reversed())
        }
        return labels
    }

    static func windowFrame(for processIdentifier: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return windows.compactMap { window -> CGRect? in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processIdentifier,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsValue = window[kCGWindowBounds as String]
            else { return nil }
            let bounds = boundsValue as! CFDictionary
            var frame = CGRect.zero
            return CGRectMakeWithDictionaryRepresentation(bounds, &frame) ? frame : nil
        }
        .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func applicationWindows(_ application: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in [
            element(application, attribute: kAXFocusedWindowAttribute),
            element(application, attribute: kAXMainWindowAttribute),
        ].compactMap({ $0 }) + elements(application, attribute: kAXWindowsAttribute) {
            if !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
        }
        return windows
    }

    private static func hasProjectAction(_ element: AXUIElement) -> Bool {
        var stack = elements(element, attribute: kAXChildrenAttribute)
        var depths: [CFHashCode: Int] = [:]
        var visited: [CFHashCode: [AXUIElement]] = [:]
        while let current = stack.popLast() {
            let depth = depths[CFHash(current)] ?? 1
            guard depth <= 3 else { continue }
            let hash = CFHash(current)
            if visited[hash]?.contains(where: { CFEqual($0, current) }) == true { continue }
            visited[hash, default: []].append(current)
            let description = string(current, attribute: kAXDescriptionAttribute).lowercased()
            if string(current, attribute: kAXRoleAttribute) == kAXPopUpButtonRole,
               description.contains("项目操作") || description.contains("project action") {
                return true
            }
            for child in elements(current, attribute: kAXChildrenAttribute) {
                depths[CFHash(child)] = depth + 1
                stack.append(child)
            }
        }
        return false
    }

    private static func value(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String {
        value(element, attribute: attribute) as? String ?? ""
    }

    private static func element(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = value(element, attribute: attribute) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }
}
