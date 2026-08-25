// Semantic design tokens (XRBM-030 DESIGN_VARIANCE 4 / VISUAL_DENSITY 5):
// colors derived from the OS SystemPalette so light/dark mode is followed
// automatically (no hand-picked dark-mode color set to keep in sync), plus
// fixed corner-radius/spacing/font-size constants shared by every page.
// Instantiated exactly once in main.qml and passed down to each page as a
// `tokens` property - deliberately NOT a pragma Singleton, so this stays a
// plain, implicitly-directory-imported QML type with no module/qmldir
// registration to keep correct under a frozen PyInstaller build.
import QtQuick

QtObject {
    id: tokens

    property SystemPalette palette: SystemPalette {
        colorGroup: SystemPalette.Active
    }

    property color background: palette.window
    property color surface: palette.base
    property color sidebarBackground: Qt.tint(palette.window, Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.025))
    property color selectionBackground: Qt.rgba(palette.highlight.r, palette.highlight.g, palette.highlight.b, 0.12)
    property color hoverBackground: Qt.rgba(palette.highlight.r, palette.highlight.g, palette.highlight.b, 0.07)
    property color textPrimary: palette.windowText
    // Keep every enabled label at the same fully opaque foreground colour.
    // Hierarchy is expressed with size and weight, not greyed-out body copy.
    property color textSecondary: palette.windowText
    property color disabledText: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.38)
    property color accent: palette.highlight
    property color accentText: palette.highlightedText
    property color border: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.16)
    // Text-input/ComboBox field background (QQC2's "base" palette role) -
    // distinct from `surface` (used for card backgrounds).
    property color fieldBackground: palette.base
    property color buttonBackground: palette.button
    property color buttonText: palette.buttonText

    // Semantic colors: only ever used for a real state (a real save error,
    // a real save/launch success, the fixed identity of the mic hotspot) -
    // never decorative (XRBM-030 Design read: "错误/成功只用于真实状态").
    property color voiceAccent: "#F2914A"
    property color successColor: "#2E7D32"
    property color errorColor: "#C62828"
    property color successBackground: Qt.rgba(successColor.r, successColor.g, successColor.b, 0.12)
    property color heatmapEmpty: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.09)

    property int cornerRadiusSmall: 9
    property int cornerRadiusLarge: 18

    property int spacingTiny: 4
    property int spacingSmall: 8
    property int spacingMedium: 12
    property int spacingLarge: 24

    // 16 px is approximately 12 pt at Windows' default 96 DPI. Keep all
    // Chinese UI copy at or above this floor, matching the Mac product's
    // accessibility contract while still following Windows DPI scaling.
    property int fontSizeSmall: 16
    property int fontSizeBody: 17
    property int fontSizeTitle: 20
    property int fontSizePageTitle: 32
}
