# Design QA: macOS 14 Compatibility and macOS 26 Liquid Glass Settings

[简体中文](design-qa.md)

## Review scope

- Settings window: minimum size 800×650 and freely resizable
- Pages: Connection & Voice, Button Mapping, Permissions & Privacy, and About
- Repository screenshots:
  - [Connection & Voice](Screenshots/connection-and-voice.png)
  - [Button Mapping](Screenshots/key-mapping.png)
  - [Permissions & Privacy](Screenshots/permissions-and-privacy.png)

## Current implementation

- The settings UI uses a narrow sidebar, header, and layered content areas. The primary actions on all four pages remain available at the minimum window size.
- Sidebar and selected-button states use low-opacity semantic-blue interactive glass.
- It uses system fonts, semantic type sizes, and system colors, following light/dark appearance, reduced transparency, and increased contrast.
- The window keeps native traffic-light controls and a meaningful logical title while hiding the visible title and titlebar separator. Page backgrounds extend to the top, blank titlebar content remains draggable, and interactive content stays clear of the window controls.
- Panels and buttons use native macOS 26 `glassEffect` and glass button styles; macOS 14/15 use system Material and standard buttons without a custom blur implementation.
- The button-mapping page reuses Resources/RC003-remote-photo.png at its original 508×1030 aspect ratio.
- Pressing a normal physical button highlights the remote diagram and selects its mapping row. The voice button has independent voice-activity state.
- The UI does not show a separate mute key that is absent from the physical remote.
- Regular UI uses product language instead of remote model codes, Bluetooth voice protocol names, button protocol names, hexadecimal button numbers, or device-identifier terminology.
- About keeps the current version and update check together, displays every language option at once, presents localized version history in a sheet, opens a glossary through the system Markdown app, and controls whether ordinary launches open the main window automatically.
- All UI text uses stable semantic keys. Localized Markdown help falls back to English when the selected language has no matching document.

## Code locations

- Window creation and minimum size: Sources/RemoteMic/RemoteMicApp.swift
- Layout, material, and remote hotspots: Sources/RemoteMic/SettingsView.swift
- Physical-button activity state: Sources/RemoteMic/HIDRemoteMonitor.swift and Sources/RemoteMic/BridgeAppModel.swift

## Conclusion

The repository screenshots show the macOS 26 Liquid Glass appearance; the same page structure automatically uses compatibility styling on macOS 14/15. No review reference depends on a local temporary directory.
