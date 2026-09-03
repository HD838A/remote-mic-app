# Remote Mic product design system

This design system translates the established Remote Mic macOS settings UI to the RC003 Windows client without imitating macOS window chrome or platform-only behavior.

## Sources consulted

- Read-only Mac implementation: `Sources/RemoteMic/SettingsView.swift`
- Mac design contract: `design-qa.md`
- Mac reference screenshots: connection, key mapping, permissions/privacy
- Shared product asset: `Resources/RC003-remote-photo.png`
- Windows implementation: `apps/windows/rc003/src/ovb_rc003/qml/*.qml`

## Product vocabulary

- A narrow navigation rail keeps the product sections visible.
- Each page starts with one large title and no redundant subtitle.
- Content uses quiet, layered surfaces and a semantic blue selection state.
- Device identity, live status and the primary recovery action stay together.
- Chinese UI text is never rendered below 12 pt.
- Windows settings links and VB-CABLE remain Windows-native; macOS controls and window chrome are not copied.

## Index

- `tokens/colors_and_type.css`: canonical visual tokens
- `brand/style-notes.md`: layout, interaction and adaptation rules
- `brand/voice-and-tone.md`: product-writing rules
- `assets/icons/RemoteMic-AppIcon.svg`: canonical microphone product mark
- `ui-kit-windows/`: representative components and assembled screen
