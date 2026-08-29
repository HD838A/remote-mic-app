# Design QA: macOS 14 Compatibility and macOS 26 Liquid Glass Settings

[简体中文](design-qa.md)

## Review scope

- Settings window: default and minimum size 860×700, freely resizable
- Pages: Connection & Voice, Button Mapping, Statistics, Permissions & Privacy, and About
- Each page header shows only its primary title, without a redundant subtitle.
- Repository screenshots:
  - [Connection & Voice](Screenshots/connection-and-voice.png)
  - [Button Mapping](Screenshots/key-mapping.png)
  - [Permissions & Privacy](Screenshots/permissions-and-privacy.png)

## Current implementation

- The settings UI uses a narrow sidebar, header, and layered content areas. The primary actions on all five pages remain available at the minimum window size. Pages remain scrollable without showing scroll bars.
- Sidebar and selected-button states use low-opacity semantic-blue interactive glass.
- It uses system fonts, semantic type sizes, and system colors, following light/dark appearance, reduced transparency, and increased contrast.
- The window keeps native traffic-light controls and a meaningful logical title while hiding the visible title and titlebar separator. Page backgrounds extend to the top, only the dedicated blank titlebar region remains draggable, page content and controls do not move the whole window, and interactive content stays clear of the window controls.
- Panels and buttons use native macOS 26 `glassEffect` and glass button styles; macOS 14/15 use system Material and standard buttons without a custom blur implementation.
- The button-mapping page reuses Resources/RC003-remote-photo.png at its original 508×1030 aspect ratio.
- Pressing a normal physical button highlights the remote diagram and selects its mapping row. The voice button has independent voice-activity state.
- The action editor provides an in-page All / Basic Keys / System & Media / Custom Actions capsule filter. Filtering is temporary, does not execute or rewrite the current mapping, and Custom Actions also exposes the existing app actions.
- The UI does not show a separate mute key that is absent from the physical remote.
- Regular UI uses product language instead of remote model codes, Bluetooth voice protocol names, button protocol names, hexadecimal button numbers, or device-identifier terminology.
- Statistics uses a prominent large Day / Week / All selector aligned to the left, shows daily bars for the latest seven days, weekly bars for the latest eight weeks, and only all-time button and voice totals in the All view while preserving expansion space.
- The Web Remote invite sheet prominently recommends the iOS app, hides the raw TestFlight URL, and provides actions to open the beta page or copy its link.
- About keeps the version number, update check, and an off-by-default pre-release update toggle together, displays every language option at once, shows the latest localized release notes inline, opens a glossary through the system Markdown app, and controls whether ordinary launches open the main window automatically. It does not include Version History or Quit buttons.
- All UI text uses stable semantic keys. Localized Markdown help falls back to English when the selected language has no matching document.

## Mandatory interaction, layout, and typography rules

- Hovering over a toggle, button, or feature entry may show a system help tag or equivalent tooltip with a supplementary explanation. Tooltip copy must use product language that ordinary users can understand and describe only the purpose, effect, or usage. It must not expose technical terminology, internal mechanisms, protocols, implementation details, or debugging information. Critical status, errors, risks, and instructions required to complete a task must remain directly visible and must not depend on hover alone.
- Keep only the short copy users need to decide and act visible by default. Supplementary explanations that can live in a tooltip should not be repeated as large blocks of persistent text. Instructions that must remain visible should be shortened, layered, or placed next to the most relevant control so explanatory copy does not crowd out primary actions.
- Controls should be compact and sized to their content. Avoid unnecessarily elongated components, especially buttons, toggle containers, choices, and status bars that stretch across the page horizontally. Use full-width layouts only when text input, progress, data presentation, or the layout genuinely requires continuous width, and keep the visual hierarchy clear.
- Every design must maintain a coherent visual order and overall polish: align the edges or text baselines of peer elements, keep equivalent controls consistently sized, and apply a consistent rhythm to page margins, section spacing, control spacing, and internal padding. Do not introduce unexplained differences in size, alignment, or spacing.
- Chinese UI text must render at 12pt or larger. Do not use 8–11pt Chinese text or allow `minimumScaleFactor` to reduce Chinese below 12pt. When space is constrained, increase control height, adjust the layout, wrap text, or truncate secondary content instead.
- Avoid drop-down lists whenever practical, especially a single long list that mixes basic keys, system actions, custom actions, and individual apps. Group larger option sets semantically and prefer in-page button grids, segmented choices, or clearly separated lists.
- At `800 × 650`, the four action-filter capsules must remain on one line in Chinese and English, use 12pt-or-larger text, and avoid horizontal scrolling or clipping in light and dark appearances.
- Flatten flows into the main page instead of relying on popovers, sheets, or consecutive confirmation dialogs. Related configuration should share one large surface where the current target, available actions, secondary settings, learning state, and test action remain visible together.
- Keep system dialogs only for file selection, required permission authorization, and irreversible destructive actions. Ordinary instructions, learning progress, success, and failure feedback should appear inline.

## Code locations

- Window creation and minimum size: Sources/RemoteMic/RemoteMicApp.swift
- Layout, material, and remote hotspots: Sources/RemoteMic/SettingsView.swift
- Physical-button activity state: Sources/RemoteMic/HIDRemoteMonitor.swift and Sources/RemoteMic/BridgeAppModel.swift

## Conclusion

The repository screenshots show the macOS 26 Liquid Glass appearance; the same page structure automatically uses compatibility styling on macOS 14/15. No review reference depends on a local temporary directory.
