import Foundation
import Testing
@testable import RemoteMic

@Suite("Settings navigation shortcut")
@MainActor
struct SettingsNavigationShortcutTests {

    // MARK: - 固定身份映射

    @Test func shortcutOrderHasExactlyNineEntries() {
        #expect(SettingsPageBehavior.sidebarShortcutOrder.count == 9)
    }

    @Test func shortcutOrderUsesFixedIdentities() {
        // 固定身份而非「当前可见顺序」：会员开通 / 私有功能启停会增删侧边栏行，
        // 位置映射会让同一个 ⌘N 静默指向别的页面。
        #expect(SettingsPageBehavior.sidebarShortcutOrder == [
            .mapping,
            .applications,
            .macros,
            .buttonProfiles,
            .membership,
            .connection,
            .transcripts,
            .about,
            .statistics,
        ])
    }

    @Test func shortcutTargetsAreRealSidebarEntries() {
        let order = SettingsPageBehavior.sidebarSectionOrder
        for section in SettingsPageBehavior.sidebarShortcutOrder {
            #expect(order.contains(section))
        }
    }

    @Test func dynamicAndContextualPagesHaveNoShortcut() {
        let order = SettingsPageBehavior.sidebarShortcutOrder
        #expect(!order.contains(.privateFeature))
        #expect(!order.contains(.commonPhrases))
        #expect(!order.contains(.permissions))
        #expect(!order.contains(.supplemental("any")))
    }

    @Test func shortcutOrderHasNoDuplicates() {
        let order = SettingsPageBehavior.sidebarShortcutOrder
        #expect(Set(order).count == order.count)
    }

    // MARK: - 导航 store

    @Test func requestAndConsumeAreSymmetric() {
        let store = SettingsNavigationStore()
        #expect(store.requestedSection == nil)

        store.request(section: .transcripts)
        #expect(store.requestedSection == .transcripts)

        store.consumeRequestedSection()
        #expect(store.requestedSection == nil)
    }

    @Test func repeatedRequestIsIdempotent() {
        let store = SettingsNavigationStore()
        // 菜单项与 NSEvent monitor 都响应同一个按键，重复请求不得叠加或抛错。
        store.request(section: .about)
        store.request(section: .about)
        #expect(store.requestedSection == .about)
        store.consumeRequestedSection()
        #expect(store.requestedSection == nil)
    }

    @Test func updateReportsCurrentSectionAndVisibleSections() {
        let store = SettingsNavigationStore()
        let visible: [SettingsSection] = [.mapping, .connection, .about]
        store.update(section: .connection, visible: visible)
        #expect(store.currentSection == .connection)
        #expect(store.visibleSections == visible)
    }

    /// 不可见的页签不应被快捷键或菜单项切过去。
    /// 这里锁定 AppDelegate 侧过滤所依赖的数据契约：visibleSections 必须准确反映可见页签。
    @Test func visibilityFilteringContract() {
        let store = SettingsNavigationStore()
        let allVisible = SettingsPageBehavior.sidebarSections(
            privateFeatureVisible: true,
            macroFeatureVisible: true,
            buttonProfilesVisible: true,
            membershipVisible: true
        )
        store.update(section: .mapping, visible: allVisible)
        #expect(store.visibleSections.contains(.macros))

        let publicOnly = SettingsPageBehavior.sidebarSections(
            privateFeatureVisible: false,
            macroFeatureVisible: false,
            buttonProfilesVisible: false,
            membershipVisible: false
        )
        store.update(section: .mapping, visible: publicOnly)
        #expect(!store.visibleSections.contains(.macros))
        #expect(!store.visibleSections.contains(.buttonProfiles))
        #expect(!store.visibleSections.contains(.membership))
        #expect(!store.visibleSections.contains(.privateFeature))
        #expect(store.visibleSections.contains(.mapping))
    }

    @Test func supplementalPagesAreInsertedAfterFixedEntries() {
        let withSupplemental = SettingsPageBehavior.sidebarSections(
            privateFeatureVisible: false,
            macroFeatureVisible: false,
            buttonProfilesVisible: false,
            membershipVisible: false,
            supplementalPageIDs: ["extra"]
        )
        #expect(withSupplemental.contains(.supplemental("extra")))
        // 固定映射不含动态页，因此 ⌘N 不会因插入位置而串位。
        #expect(!SettingsPageBehavior.sidebarShortcutOrder.contains(.supplemental("extra")))
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
        let rootViewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicRootView.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("case \"1\", \"2\", \"3\", \"4\", \"5\", \"6\", \"7\", \"8\", \"9\":"))
        #expect(appSource.contains("func menuNeedsUpdate(_ menu: NSMenu)"))
        #expect(appSource.contains("settingsNavigation.visibleSections"))
        #expect(appSource.contains("settingsNavigation: settingsNavigation"))

        // 治理约束：键盘事件必须集中在 AppDelegate。
        #expect(!settingsSource.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(settingsSource.contains(".onReceive(settingsNavigation.$requestedSection)"))
        #expect(rootViewSource.contains("settingsNavigation: settingsNavigation"))
    }

    @Test func sheetKeyboardShortcutsArePresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(source.contains(".keyboardShortcut(.cancelAction)"))
        #expect(source.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test func goMenuIsLocalizedInBothLanguages() throws {
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
            #expect(source.contains("\"menu.go\" = "))
        }
    }
}
