# Design QA: macOS 14 Compatibility and macOS 26 Liquid Glass Settings

[简体中文](design-qa.md)

This file is a convenience translation of the current mandatory design rules. The Chinese `design-qa.md` is authoritative and historical dated QA records in that file are audit evidence, not independent product rules. If this translation differs from the Chinese source, follow the Chinese source and update this file.

## Product names and promotional copy

| Context | Required name |
| --- | --- |
| English product name | `SayAll` |
| Product reference in English promotional copy | `SayAll App` |
| Chinese product name | 无线麦 SayAll |
| Product reference in Chinese promotional copy | 无线麦 SayAll App |

- Do not use `Remote Mic`, `Wireless Mic`, or `SayAll Wireless Mic` as the English product name.
- Keep one ASCII space between the Chinese and English parts. Do not use the old joined name, the `.app` suffix, or the Chinese-only short name for the current product.
- Apply these names to pages, buttons, errors, permission text, accessibility labels, help, and release notes.
- These rules change text only. Keep layout, behavior, filenames, paths, bundle identifiers, protocols, data keys, and compatibility identifiers unchanged.
- Keep exact legacy filenames when explaining installation migration. Generic microphone descriptions are not product names.

## Review scope

- Settings window: default and minimum content size 1020×772, freely resizable above that minimum. An 800×650 offscreen render is only a narrow-width stress check, not a supported production window size.
- Pages: Connection & Voice, Button Mapping, Profile, Reflections, and Settings, including Permissions & Privacy, General, Diagnostics & Logs and Support.
- First-run Onboarding: approximately 1020×772, without step numbers, totals, percentages, Skip, or Continue Later.
- Each page header shows only its primary title, without a redundant subtitle.
- Repository screenshots:
  - [Connection & Voice](Screenshots/connection-and-voice.png)
  - [Button Mapping](Screenshots/key-mapping.png)
  - [Permissions & Privacy](Screenshots/permissions-and-privacy.png)

## Screenshots and design drafts

- The in-repository screenshots linked above are historical assets and are not extended further. New production screenshots and design drafts follow the [screenshot and design-draft archiving rules](AGENTS.md#截图与设计稿归档规范) in `AGENTS.md`: attach them to the PR or link them persistently, and keep only a `manifest.json` index in the repository.
- `Screenshots/...` paths inside historical QA records only describe the evidence available at that time. When a path leaves the repository or is missing, use the format, dimensions, and SHA-256 recorded in the index; do not infer the current implementation from it.
- Build-required assets (app icons, onboarding tool images, status icons, fonts) are exempt.

## Current implementation

- The settings UI uses a narrow sidebar, header, and layered content areas. Primary actions on every visible page remain available at the production minimum window size. Pages remain scrollable without showing scroll bars.
- Sidebar and selected-button states use low-opacity semantic-blue interactive glass.
- The bottom Profile sidebar entry uses the system `person.crop.circle` icon. The sidebar and Settings brand names use Oxanium SemiBold 600; other text uses system fonts, semantic type sizes, and system colors, following light/dark appearance, reduced transparency, and increased contrast.
- The window keeps native traffic-light controls and a meaningful logical title while hiding the visible title and titlebar separator. Page backgrounds extend to the top, only the dedicated blank titlebar region remains draggable, page content and controls do not move the whole window, and interactive content stays clear of the window controls.
- Except for the flat Profile cards and sharing buttons, panels and buttons use native macOS 26 `glassEffect` and glass button styles; macOS 14/15 use system Material and standard buttons without a custom blur implementation.
- The button-mapping page reuses Resources/RC003-remote-photo.png at its original 508×1030 aspect ratio.
- Pressing a normal physical button highlights the remote diagram and selects its mapping row. The voice button has independent voice-activity state.
- The action editor has five peer filters and sections: Basic Keys / System & Media / Custom Actions / Common Phrases / Open an App. On first open, all groups are visible without an All button. App actions stay expanded, with Open Custom App last; both common phrase buttons use the same dimensions, border and corner style as other actions. Filtering is temporary and resets when editing another button.
- The UI does not show a separate mute key that is absent from the physical remote.
- Regular UI uses product language instead of remote model codes, Bluetooth voice protocol names, button protocol names, hexadecimal button numbers, or device-identifier terminology.
- Profile sharing appears below the page title and before the KPIs, expanding inline. Settings and the sidebar have no separate sharing entry. Profile panels use the remote device card's subtle fill, 10pt corners, and thin border instead of glass; the local privacy indicator uses plain text and an icon.
- Profile uses four single-row KPIs in a wide window and may adapt to two columns in a narrow layout. Rankings appear beside a six-month square-cell calendar heatmap using semantic blue; the former bar chart and Less–More legend are not part of the current design.
- The Web Remote invite sheet prominently recommends the iOS app, hides the raw TestFlight URL, and provides actions to open the beta page or copy its link.
- Settings keeps the current version, available update, Check for Updates, release notes, and the off-by-default pre-release toggle together. Permissions & Privacy precedes General, followed by Diagnostics & Logs and Support. Language choices remain visible without a drop-down; the page does not show a glossary, Version History, or Quit button.
- General uses inline icon buttons for the app-icon choice and only shows icon resources actually included in the installed build. A selection immediately updates the Dock, app switcher, and Settings branding and persists across launches; a missing resource falls back to the default icon without showing an unavailable placeholder.
- All UI text uses stable semantic keys. Localized Markdown help falls back to English when the selected language has no matching document.

## Approved sidebar design

On 2026-10-29 the user approved the [version 8 HTML design](Screenshots/design-drafts/sidebar-compact/v8/review.html) for implementation. Its Markdown source, original PNGs and digest manifest are stored beside it without changing the reviewed bytes. Statements such as “not implemented” describe the review-time state.

On 2026-10-31 the user asked for a narrower sidebar. The width is no longer fixed at `136pt`; it is measured from the widest visible row (brand header included) within `104–136pt`, keeping `15pt` from the text to both the leading and trailing edges instead of stacking spare space to the right of the labels. Both languages measure about `129pt` because the brand header is the widest block; longer English entries grow the width up to the `136pt` cap.

Verification screenshots live in `Screenshots/design-drafts/sidebar-width/` (`sidebar-width-zh-hans-dark.png`, `sidebar-width-zh-hans-light.png`, `sidebar-width-en-dark.png`, `sidebar-width-en-light.png`), captured as `2040 × 1544` 2× images of a `1020 × 772` window.

- Measure the sidebar width from its content within `104–136pt`. Place the icon to the left of the text for the brand, every navigation entry and the bottom account entry.
- Use a `44 × 44pt` brand logo, `16pt` below the window control region and `15pt` from the sidebar edge. Keep an `8pt` horizontal gap to the brand text.
- Use `16pt` Oxanium SemiBold 600 for sidebar SayAll. Move it `2pt` down from version 5. Keep the `12pt` system-font version closely below it and read the actual bundle version.
- Use `18pt` navigation icons and `13pt` system Semibold labels. Set the icon column `15pt` from the left edge for optical alignment with the logo. Keep an `8pt` icon-to-text gap and left-align labels.
- Navigation rows have a `44pt` minimum height. Keep the full `Button Profiles` name and wrap by available width instead of renaming it to `Profiles`. Center the icon vertically against the entire text block. Grow rows for additional lines without shrinking or clipping text.
- Keep `person.crop.circle` for the account entry, with a `56pt` minimum account region and the same columns and centering. Wrap long names fully by available width, without forced breaks every eight characters or ellipses. Grow the account region when needed.
- Use a rounded, low-opacity accent selection background. Put the Settings update dot at the row trailing edge and reserve room for it.
- Keep the brand and account fixed and retain vertical scrolling for the middle navigation. Validate all enabled entries at the `1020 × 772` production minimum in Chinese/English and light/dark appearances. Do not hide entries or shrink Chinese text to remove scrolling.
- Preserve existing names, ordering, visibility, account sources and behavior. Optional entries and the fictitious name in the draft are layout fixtures, not new features or real account state. Keep Oxanium 600 for the Settings brand too.

## Mandatory interaction, layout, and typography rules

- Secondary-page headers place the Back button on the left and the page title immediately to its right, on one vertically centered row. Use only “Back” as the label, with a hit area at least 72pt wide and 44pt high; the entire button area must respond to clicks.
- Card buttons and buttons with a background or border must respond across the entire card or bordered shape, including text, icons, and empty space. Clicking any of these areas must run the same button action. Separate secondary buttons within a card must run only their own actions; disabled buttons must not respond. During acceptance, click the text, icons, empty space, and inside edge of the border separately.

- User-facing screens must use product language and describe only the current state, actual impact, and actions the user can take. They must not expose engineering, testing, or internal acceptance status such as “pending device validation,” “compatibility acceptance required,” “regression pending,” “automation/CI passed,” “candidate implementation,” “in development,” or “under validation.” Capabilities that have not completed acceptance must remain hidden, unreleased, or absent from supported and recommended lists. If a published capability is currently unavailable, present a user-understandable conclusion such as “not supported” or “temporarily unavailable” together with the next step. Technical reason codes and acceptance status belong only in redacted logs, diagnostics explicitly copied by the user, and internal documentation.
- Hovering over a toggle, button, or feature entry may show a system help tag or equivalent tooltip with a supplementary explanation. Tooltip copy must use product language that ordinary users can understand and describe only the purpose, effect, or usage. It must not expose technical terminology, internal mechanisms, protocols, implementation details, or debugging information. Critical status, errors, risks, and instructions required to complete a task must remain directly visible and must not depend on hover alone.
- Keep only the short copy users need to decide and act visible by default. Supplementary explanations that can live in a tooltip should not be repeated as large blocks of persistent text. Instructions that must remain visible should be shortened, layered, or placed next to the most relevant control so explanatory copy does not crowd out primary actions.
- Controls should be compact and sized to their content. Avoid unnecessarily elongated components, especially buttons, toggle containers, choices, and status bars that stretch across the page horizontally. Use full-width layouts only when text input, progress, data presentation, or the layout genuinely requires continuous width, and keep the visual hierarchy clear.
- Every design must maintain a coherent visual order and overall polish: align the edges or text baselines of peer elements, keep equivalent controls consistently sized, and apply a consistent rhythm to page margins, section spacing, control spacing, and internal padding. Do not introduce unexplained differences in size, alignment, or spacing.
- Chinese UI text must render at 12pt or larger. Do not use 8–11pt Chinese text or allow `minimumScaleFactor` to reduce Chinese below 12pt. When space is constrained, increase control height, adjust the layout, wrap text, or truncate secondary content instead.
- Avoid drop-down lists whenever practical, especially a single long list that mixes basic keys, system actions, custom actions, and individual apps. Group larger option sets semantically and prefer in-page button grids, segmented choices, or clearly separated lists.
- At the `800 × 650` offscreen stress size, the five action-filter capsules must remain on one line in Chinese and English, use 12pt-or-larger text, and avoid horizontal scrolling or clipped hit areas in light and dark appearances. Long labels may truncate while accessibility retains the full name. Real window interaction is validated at the production minimum of `1020 × 772`.
- Physical-keyboard shortcut recording accepts an unmodified single key, a key combination, or one standalone left/right Command, Option, Control, Shift, or Fn key. A modifier press remains pending until either a main key completes the combination or the modifier is released alone.
- Prefer in-page controls for primary tasks and related settings. Keep frequent workflows, the current target, required actions, and critical status visible. Show routine instructions, progress, and results beside the related controls.
- Popovers and sheets may serve brief choices, secondary edits, and native system tasks. They must support cancel, keyboard access, and accessibility, preserve context, and provide a clear return path. Do not hide required steps or critical errors behind consecutive overlays.
- Use suitable system interactions for file selection, permissions, and irreversible actions. Product specs that require a specific flow to remain inline still apply.

## Code locations

- Window creation and minimum size: Sources/RemoteMic/RemoteMicApp.swift
- Layout, material, and remote hotspots: Sources/RemoteMic/SettingsView.swift
- Physical-button activity state: Sources/RemoteMic/HIDRemoteMonitor.swift and Sources/RemoteMic/BridgeAppModel.swift

## Conclusion

The repository screenshots show the macOS 26 Liquid Glass appearance; the same page structure automatically uses compatibility styling on macOS 14/15. No review reference depends on a local temporary directory.

## Onboarding validation scope

Use the production page and scenario list in [Testing/FirstRunOnboarding.md](Testing/FirstRunOnboarding.md). Derive counts from enabled sources, pages, languages, appearances, and extra states. Do not maintain another fixed count here. Flow and shared-layout changes require full checks. Text-only and local changes use the targeted checks in `AGENTS.md`. Save evidence in persistent storage and inspect every image. Screenshots do not prove real permissions, devices, audio, or text delivery.
