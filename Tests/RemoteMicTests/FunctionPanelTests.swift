import Foundation
import Testing
@testable import RemoteMic

@Suite("Function panel")
@MainActor
struct FunctionPanelTests {
    @Test func catalogOrdersFavoritesBeforeConfiguredAndLibraryEntries() {
        let macros = [
            FunctionPanelMacro(id: "macro-1", name: "One", stepCount: 2),
            FunctionPanelMacro(id: "macro-2", name: "Two", stepCount: 4),
        ]
        let favorites = [
            FunctionPanelCatalog.macroID("macro-2"),
            FunctionPanelCatalog.actionID(.showDesktop),
        ]
        let configured = [
            ConfiguredButtonAction(action: .showDesktop, shortcut: nil),
            ConfiguredButtonAction(action: .openCommonPhrases, shortcut: nil),
            ConfiguredButtonAction(
                action: .combinationAction,
                shortcut: nil,
                macroID: "macro-1"
            ),
            ConfiguredButtonAction(action: .openFunctionPanel, shortcut: nil),
        ]

        let items = FunctionPanelCatalog.items(
            favoriteIDs: favorites,
            configuredActions: configured,
            macros: macros,
            text: makeText(),
            availability: makeAvailability()
        )

        #expect(items.map(\.id) == [
            FunctionPanelCatalog.actionID(.showDesktop),
            FunctionPanelCatalog.macroID("macro-2"),
            FunctionPanelCatalog.actionID(.openCommonPhrases),
            FunctionPanelCatalog.macroID("macro-1"),
        ])
        #expect(items.map(\.isAvailable) == [true, true, true, true])
        #expect(!items.contains { $0.id == FunctionPanelCatalog.actionID(.openFunctionPanel) })
    }

    @Test func staleMacroFavoriteStaysVisibleButRejected() {
        let items = FunctionPanelCatalog.items(
            favoriteIDs: [FunctionPanelCatalog.macroID("deleted")],
            configuredActions: [],
            macros: [],
            text: makeText(),
            availability: makeAvailability(macroAvailable: { _ in false })
        )

        #expect(items.count == 1)
        #expect(items[0].id == FunctionPanelCatalog.macroID("deleted"))
        #expect(items[0].title == "combination")
        #expect(items[0].unavailableReasonKey == "function_panel.unavailable.macro_deleted")
        #expect(!items[0].isAvailable)
    }

    @Test func favoritesSheetUsesCatalogOrderAndKeepsUnknownFavoritesAsTail() {
        let macros = [FunctionPanelMacro(id: "macro-1", name: "One", stepCount: 1)]
        let sections = FunctionPanelCatalog.favoriteSections(
            macros: macros,
            text: makeText(),
            availability: makeAvailability()
        )
        let ids = sections.flatMap(\.entries).map(\.id)

        #expect(ids.contains(FunctionPanelCatalog.macroID("macro-1")))
        #expect(ids.contains(FunctionPanelCatalog.actionID(.showDesktop)))
        #expect(!ids.contains(FunctionPanelCatalog.actionID(.openFunctionPanel)))
        #expect(!ids.contains(FunctionPanelCatalog.actionID(.customShortcut)))
        #expect(!ids.contains(FunctionPanelCatalog.actionID(.openCustomApplication)))
        #expect(!ids.contains(FunctionPanelCatalog.actionID(.combinationAction)))

        let ordered = FunctionPanelCatalog.orderedFavoriteIDs(
            from: [
                FunctionPanelCatalog.macroID("macro-1"),
                FunctionPanelCatalog.actionID(.showDesktop),
                FunctionPanelCatalog.macroID("missing"),
            ],
            sections: sections
        )
        #expect(ordered == [
            FunctionPanelCatalog.actionID(.showDesktop),
            FunctionPanelCatalog.macroID("macro-1"),
            FunctionPanelCatalog.macroID("missing"),
        ])
    }

    @Test func availabilityReportsTheFirstConcreteReason() {
        let availability = makeAvailability(
            accessibilityTrusted: false,
            membershipAvailable: false,
            experimentalRecordingEnabled: false,
            installedBundleIdentifiers: []
        )

        #expect(availability.reasonKey(
            for: ConfiguredButtonAction(action: .openFunctionPanel, shortcut: nil)
        ) == "function_panel.unavailable.disabled")
        #expect(availability.reasonKey(
            for: ConfiguredButtonAction(action: .toggleLongRecording, shortcut: nil)
        ) == "function_panel.unavailable.disabled")
        #expect(availability.reasonKey(
            for: ConfiguredButtonAction(action: .openCommonPhrases, shortcut: nil)
        ) == "function_panel.unavailable.membership")
        #expect(availability.reasonKey(
            for: ConfiguredButtonAction(action: .openWeChat, shortcut: nil)
        ) == "function_panel.unavailable.app_missing")
        #expect(availability.reasonKey(
            for: ConfiguredButtonAction(action: .focusInput, shortcut: nil)
        ) == "function_panel.unavailable.focus_input")
        #expect(availability.reasonKey(
            for: ConfiguredButtonAction(action: .commandCopy, shortcut: nil)
        ) == "function_panel.unavailable.accessibility")
        #expect(makeAvailability().reasonKey(
            for: ConfiguredButtonAction(action: .showDesktop, shortcut: nil)
        ) == nil)
    }

    @Test func layoutBoundsAndSelectionWrapAreDeterministic() {
        #expect(FunctionPanelController.panelWidth(forItemCount: 0) == 420)
        #expect(FunctionPanelController.panelHeight(forItemCount: 0) == 120)
        #expect(FunctionPanelController.panelWidth(forItemCount: 1) == 600)
        #expect(FunctionPanelController.panelWidth(forItemCount: 5) == 600)
        #expect(FunctionPanelController.panelWidth(forItemCount: 9) == 1056)
        #expect(FunctionPanelController.panelWidth(forItemCount: 12) == 1056)
        #expect(FunctionPanelController.panelHeight(forItemCount: 1) == 172)
        #expect(FunctionPanelController.wrappedIndex(0, delta: -1, count: 3) == 2)
        #expect(FunctionPanelController.wrappedIndex(2, delta: 1, count: 3) == 0)
        #expect(FunctionPanelController.wrappedIndex(0, delta: 1, count: 0) == 0)
    }

    private func makeText() -> FunctionPanelText {
        FunctionPanelText(
            actionTitle: { $0.rawValue },
            macroTitle: { $0 },
            configuredTitle: { $0.action.rawValue },
            categoryTitle: { $0.rawValue },
            combinationTitle: "combination",
            commonPhrasesTitle: "common",
            macroStepCount: { "\($0) steps" },
            reasonText: { $0 }
        )
    }

    private func makeAvailability(
        accessibilityTrusted: Bool = true,
        membershipAvailable: Bool = true,
        experimentalRecordingEnabled: Bool = true,
        installedBundleIdentifiers: Set<String> = Set(
            PresetApplication.allCases.map(\.bundleIdentifier)
        ),
        macroAvailable: @escaping (String) -> Bool = { _ in true }
    ) -> FunctionPanelAvailability {
        FunctionPanelAvailability(
            accessibilityTrusted: accessibilityTrusted,
            membershipAvailable: membershipAvailable,
            experimentalRecordingEnabled: experimentalRecordingEnabled,
            installedBundleIdentifiers: installedBundleIdentifiers,
            customApplicationExists: { _ in true },
            customApplicationInstalled: { _ in true },
            macroAvailable: macroAvailable,
            macroFeatureVisible: true
        )
    }
}
