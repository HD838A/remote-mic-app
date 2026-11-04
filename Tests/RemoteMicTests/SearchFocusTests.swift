import Foundation
import Testing
@testable import RemoteMic

/// ⌘F 搜索聚焦的契约与宿主侧行为。
///
/// `.serialized`：`NotificationCenter.default` 是进程级全局通道，端到端用例会
/// 真实 post 通知；串行执行避免同 Suite 内其他 coordinator 被误触。
@Suite("Search focus", .serialized)
@MainActor
struct SearchFocusTests {

    /// `NotificationCenter` 的回调是 `@Sendable`，采集器必须自己保证线程安全。
    private final class NotificationCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [[AnyHashable: Any]] = []
        private var observedCount = 0

        func append(_ userInfo: [AnyHashable: Any]) {
            lock.lock()
            defer { lock.unlock() }
            payloads.append(userInfo)
        }

        func record() {
            lock.lock()
            defer { lock.unlock() }
            observedCount += 1
        }

        var snapshot: [[AnyHashable: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return payloads
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return observedCount
        }
    }

    private let mapping = SettingsSection.mapping.rawValue

    private func registration(
        _ section: String,
        isRegistered: Bool
    ) -> [AnyHashable: Any] {
        [
            SearchFocusRequest.sectionUserInfoKey: section,
            SearchFocusRequest.isRegisteredUserInfoKey: isRegistered,
        ]
    }

    // MARK: - 跨仓契约

    @Test func contractNamesAreStable() {
        // 私有包无法 import 公开仓，只能复制这两个字面量。
        // 改动必须同步私有包与 `SearchFocusContract.swift`，否则私有页 ⌘F 静默失效。
        #expect(SearchFocusRequest.registerNotification.rawValue == "sayall.search.focus.register")
        #expect(SearchFocusRequest.focusNotification.rawValue == "sayall.search.focus.request")
        #expect(SearchFocusRequest.sectionUserInfoKey == "section")
        #expect(SearchFocusRequest.isRegisteredUserInfoKey == "isRegistered")
    }

    // MARK: - 登记状态

    @Test func registrationIsSymmetricAndIdempotent() {
        let coordinator = SearchFocusCoordinator()
        #expect(!coordinator.hasRegisteredSearchField)
        #expect(coordinator.registeredSections.isEmpty)

        coordinator.applyRegistration(userInfo: registration(mapping, isRegistered: true))
        #expect(coordinator.registeredSections == [mapping])
        #expect(coordinator.hasRegisteredSearchField)

        // 菜单每次打开都会走一次校验；登记状态查询不得有副作用。
        #expect(coordinator.hasRegisteredSearchField)
        #expect(coordinator.registeredSections == [mapping])

        // 重复登记幂等（视图可能被 SwiftUI 重复 onAppear）。
        coordinator.applyRegistration(userInfo: registration(mapping, isRegistered: true))
        #expect(coordinator.registeredSections == [mapping])

        coordinator.applyRegistration(userInfo: registration(mapping, isRegistered: false))
        #expect(coordinator.registeredSections.isEmpty)
        #expect(!coordinator.hasRegisteredSearchField)
    }

    @Test func multipleSectionsAreIndependent() {
        let coordinator = SearchFocusCoordinator()
        let macros = SettingsSection.macros.rawValue
        coordinator.applyRegistration(userInfo: registration(mapping, isRegistered: true))
        coordinator.applyRegistration(userInfo: registration(macros, isRegistered: true))
        #expect(coordinator.registeredSections == [mapping, macros])

        coordinator.applyRegistration(userInfo: registration(mapping, isRegistered: false))
        #expect(coordinator.registeredSections == [macros])
        #expect(coordinator.hasRegisteredSearchField)
    }

    @Test func malformedRegistrationIsIgnored() {
        let coordinator = SearchFocusCoordinator()
        coordinator.applyRegistration(userInfo: nil)
        coordinator.applyRegistration(userInfo: [:])
        coordinator.applyRegistration(userInfo: [
            SearchFocusRequest.sectionUserInfoKey: mapping,
        ])
        coordinator.applyRegistration(userInfo: [
            SearchFocusRequest.isRegisteredUserInfoKey: true,
        ])
        coordinator.applyRegistration(userInfo: [
            SearchFocusRequest.sectionUserInfoKey: 42,
            SearchFocusRequest.isRegisteredUserInfoKey: true,
        ])
        #expect(coordinator.registeredSections.isEmpty)
        #expect(!coordinator.hasRegisteredSearchField)
    }

    // MARK: - 通知通道

    @Test func registrationHelperPostsContractPayload() {
        let collector = NotificationCollector()
        let observer = NotificationCenter.default.addObserver(
            forName: SearchFocusRequest.registerNotification,
            object: nil,
            queue: nil
        ) { notification in
            if let userInfo = notification.userInfo {
                collector.append(userInfo)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        SearchFieldRegistration.post(section: mapping, isRegistered: true)
        SearchFieldRegistration.post(section: mapping, isRegistered: false)

        let received = collector.snapshot
        #expect(received.count == 2)
        #expect(received.first?[SearchFocusRequest.sectionUserInfoKey] as? String == mapping)
        #expect(received.first?[SearchFocusRequest.isRegisteredUserInfoKey] as? Bool == true)
        #expect(received.last?[SearchFocusRequest.isRegisteredUserInfoKey] as? Bool == false)
    }

    @Test func requestFocusPostsOncePerCall() {
        let coordinator = SearchFocusCoordinator()
        let collector = NotificationCollector()
        let observer = NotificationCenter.default.addObserver(
            forName: SearchFocusRequest.focusNotification,
            object: nil,
            queue: nil
        ) { _ in collector.record() }
        defer { NotificationCenter.default.removeObserver(observer) }

        coordinator.requestFocus()
        #expect(collector.count == 1)

        // 幂等：菜单项与 NSEvent monitor 都响应同一个按键；每次请求恰好一次广播，
        // 且请求本身不改动登记状态。
        coordinator.requestFocus()
        #expect(collector.count == 2)
        #expect(coordinator.registeredSections.isEmpty)
    }

    @Test func coordinatorAppliesRegistrationFromNotification() async throws {
        let coordinator = SearchFocusCoordinator()
        SearchFieldRegistration.post(section: mapping, isRegistered: true)
        // addObserver(forName:queue:.main) 是异步投递，沿用仓库既有的轮询等待范式。
        for _ in 0..<200 where !coordinator.hasRegisteredSearchField {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.registeredSections == [mapping])

        SearchFieldRegistration.post(section: mapping, isRegistered: false)
        for _ in 0..<200 where coordinator.hasRegisteredSearchField {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(coordinator.registeredSections.isEmpty)
    }

    // MARK: - 源码守卫

    @Test func keyboardHandlingStaysInAppDelegate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("case \"f\":"))
        #expect(appSource.contains("common.action.find"))
        #expect(appSource.contains("func performSearchFocus()"))
        #expect(appSource.contains("searchFocusCoordinator.hasRegisteredSearchField"))

        // 治理约束：键盘事件必须集中在 AppDelegate，不得回到设置视图。
        #expect(!settingsSource.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(settingsSource.contains(".focused($isMappingMacroSearchFocused)"))
        #expect(settingsSource.contains("SearchFieldRegistration.post("))
        #expect(settingsSource.contains("SearchFocusRequest.focusNotification"))
    }

    /// ⌘F 不得干扰「录入自定义快捷键」：录入态的 CGEvent tap 在 headInsertEventTap
    /// 位置先吞掉 keyDown，事件根本到不了本 App 的 NSEvent 本地监听。
    /// 这里锁定该前提，防止日后有人挪动 tap 位置或改变吞噬条件后出现静默回归。
    @Test func shortcutCaptureTapPrecedesLocalMonitor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/RemoteMic/ShortcutCaptureMonitor.swift"),
            encoding: .utf8
        )
        #expect(source.contains("tap: .cgSessionEventTap"))
        #expect(source.contains("place: .headInsertEventTap"))
        #expect(source.contains("? nil\n        : Unmanaged.passUnretained(event)"))
    }

    @Test func findMenuItemIsLocalizedInBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for language in ["zh-Hans", "en"] {
            let source = try String(
                contentsOf: root.appendingPathComponent(
                    "Resources/\(language).lproj/Localizable.strings"),
                encoding: .utf8
            )
            #expect(source.contains("\"common.action.find\" = "))
        }
    }

    /// 私有包契约文件的字面量一致性。CI 与公开构建没有私有仓 checkout，
    /// 文件不存在时静默跳过，不视为失败。
    @Test func privatePackageContractsMatchWhenPresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let base = ".private-dependencies/release-control/sayall-private-platform/packages"
        let candidates = [
            "\(base)/macos-combination-actions/Sources/SayAllMacroRemoteMic/SearchFocusContract.swift",
            "\(base)/macos-common-phrases/Sources/SayAllCommonPhrases/SearchFocusContract.swift",
        ]
        for candidate in candidates {
            let url = root.appendingPathComponent(candidate)
            guard FileManager.default.fileExists(atPath: url.path),
                  let source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            #expect(source.contains("sayall.search.focus.register"))
            #expect(source.contains("sayall.search.focus.request"))
            #expect(source.contains("\"section\""))
            #expect(source.contains("\"isRegistered\""))
        }
    }
}
