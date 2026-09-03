// Top-level Windows settings window (XRBM-030 In-scope item 2). It uses a
// native Qt Quick window and Windows' own title-bar/Fluent chrome.
//
// `SettingsController`/`ButtonMappingModel` below are QML SINGLETON types
// (registered via qmlRegisterSingletonInstance in
// qt_settings_app.run_settings_window(), imported from the
// "OvbRc003Settings" module) - deliberately not exposed as
// engine.rootContext() context properties. During this task, an
// isolated repro proved that a context property can read back as null the
// first time it is accessed from a binding evaluated during a nested
// component's own construction (e.g. inside a ScrollView's deferred content,
// or a ListView's currentIndex binding, before an externally-supplied
// property has finished propagating down to it) - a QML singleton has no
// such hazard, since every file that imports the module gets the same
// already-fully-constructed instance immediately, resolved once by the
// type system rather than walked through a context hierarchy each time.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

ApplicationWindow {
    id: window
    title: qsTr("Remote Mic 设置")
    width: 1180
    height: 820
    minimumWidth: 900
    minimumHeight: 680
    visible: true
    font.family: "Microsoft YaHei UI"
    font.pixelSize: 16

    property Tokens tokens: Tokens {}

    color: tokens.background

    // XRBM-030 RETRY 1 blocker 2: Qt Quick Controls' "FluentWinUI3" style
    // resolves its OWN default text/background colors from
    // Qt.styleHints.colorScheme independently of Tokens.qml's colors (which
    // come from the plain QtQuick `SystemPalette` type instead) - under the
    // offscreen QPA platform (no real desktop/compositor), colorScheme
    // reports `Unknown`, and FluentWinUI3 falls back to a DARK-styled
    // control appearance (white button/tab/field text) while SystemPalette
    // separately falls back to a LIGHT one (white base, black text) - two
    // independent "default" guesses that disagree, producing white text on
    // a light background. Explicitly setting this window's own `palette`
    // (which Qt Quick Controls propagates down to every descendant Button/
    // TabButton/ComboBox/TextField automatically, verified by a minimal
    // isolated repro during this task) from the SAME SystemPalette-derived
    // tokens used for the rest of this window keeps both systems reading
    // from one source of truth in both light AND dark real Windows
    // sessions - this does not hard-code a light-only palette, since every
    // value below is itself OS-derived via Tokens.qml.
    palette.window: tokens.background
    palette.windowText: tokens.textPrimary
    palette.button: tokens.buttonBackground
    palette.buttonText: tokens.buttonText
    palette.base: tokens.fieldBackground
    palette.text: tokens.textPrimary
    palette.highlight: tokens.accent
    palette.highlightedText: tokens.accentText

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.preferredWidth: 124
            Layout.fillHeight: true
            color: tokens.sidebarBackground
            border.color: tokens.border
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: tokens.spacingMedium
                spacing: tokens.spacingSmall

                Label {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: qsTr("Remote Mic")
                    color: tokens.textSecondary
                    font.pixelSize: tokens.fontSizeSmall
                    font.bold: true
                }

                Item {
                    id: tabBar
                    objectName: "tabBar"  // stable test/automation hook
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    property int currentIndex: 0

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: tokens.spacingSmall

                        TabButton {
                            objectName: "connectionTabButton"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 82
                            text: qsTr("连接")
                            checked: tabBar.currentIndex === 0
                            checkable: false
                            onClicked: tabBar.currentIndex = 0
                            Accessible.name: text
                            background: Rectangle {
                                radius: 14
                                color: parent.checked ? tokens.selectionBackground
                                    : (parent.hovered ? tokens.hoverBackground : "transparent")
                            }
                            contentItem: ColumnLayout {
                                spacing: tokens.spacingTiny
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "\uE71B"
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.family: "Segoe Fluent Icons"
                                    font.pixelSize: 24
                                    font.bold: true
                                }
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: qsTr("连接")
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.pixelSize: tokens.fontSizeSmall
                                    font.bold: true
                                }
                            }
                        }

                        TabButton {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 82
                            text: SettingsController.mappingPageTitle
                            checked: tabBar.currentIndex === 1
                            checkable: false
                            onClicked: tabBar.currentIndex = 1
                            Accessible.name: text
                            background: Rectangle {
                                radius: 14
                                color: parent.checked ? tokens.selectionBackground
                                    : (parent.hovered ? tokens.hoverBackground : "transparent")
                            }
                            contentItem: ColumnLayout {
                                spacing: tokens.spacingTiny
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "\uE765"
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.family: "Segoe Fluent Icons"
                                    font.pixelSize: 24
                                }
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: SettingsController.mappingPageTitle
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.pixelSize: tokens.fontSizeSmall
                                    font.bold: true
                                }
                            }
                        }

                        TabButton {
                            objectName: "statisticsTabButton"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 82
                            text: qsTr("统计")
                            checked: tabBar.currentIndex === 2
                            checkable: false
                            onClicked: tabBar.currentIndex = 2
                            Accessible.name: text
                            background: Rectangle {
                                radius: 14
                                color: parent.checked ? tokens.selectionBackground
                                    : (parent.hovered ? tokens.hoverBackground : "transparent")
                            }
                            contentItem: ColumnLayout {
                                spacing: tokens.spacingTiny
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "\uE9D2"
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.family: "Segoe Fluent Icons"
                                    font.pixelSize: 24
                                    font.bold: true
                                }
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: qsTr("统计")
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.pixelSize: tokens.fontSizeSmall
                                    font.bold: true
                                }
                            }
                        }

                        TabButton {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 82
                            text: qsTr("权限")
                            checked: tabBar.currentIndex === 3
                            checkable: false
                            onClicked: tabBar.currentIndex = 3
                            Accessible.name: text
                            background: Rectangle {
                                radius: 14
                                color: parent.checked ? tokens.selectionBackground
                                    : (parent.hovered ? tokens.hoverBackground : "transparent")
                            }
                            contentItem: ColumnLayout {
                                spacing: tokens.spacingTiny
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "\uE83D"
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.family: "Segoe Fluent Icons"
                                    font.pixelSize: 24
                                    font.bold: true
                                }
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: qsTr("权限")
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.pixelSize: tokens.fontSizeSmall
                                    font.bold: true
                                }
                            }
                        }

                        TabButton {
                            objectName: "diagnosticsTabButton"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 82
                            text: qsTr("检查")
                            checked: tabBar.currentIndex === 4
                            checkable: false
                            onClicked: tabBar.currentIndex = 4
                            Accessible.name: qsTr("检查与修复")
                            background: Rectangle {
                                radius: 14
                                color: parent.checked ? tokens.selectionBackground
                                    : (parent.hovered ? tokens.hoverBackground : "transparent")
                            }
                            contentItem: ColumnLayout {
                                spacing: tokens.spacingTiny
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: "\uE90F"
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.family: "Segoe Fluent Icons"
                                    font.pixelSize: 24
                                    font.bold: true
                                }
                                Label {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: qsTr("检查")
                                    color: parent.parent.checked ? tokens.accent : tokens.textSecondary
                                    font.pixelSize: tokens.fontSizeSmall
                                    font.bold: true
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            Label {
                Layout.fillWidth: true
                Layout.leftMargin: tokens.spacingLarge
                Layout.rightMargin: tokens.spacingLarge
                Layout.topMargin: tokens.spacingLarge
                Layout.bottomMargin: tokens.spacingSmall
                text: [qsTr("连接与语音"), SettingsController.mappingPageTitle,
                    qsTr("使用统计"), qsTr("权限与系统"), qsTr("检查与修复")][tabBar.currentIndex]
                color: tokens.textPrimary
                font.pixelSize: tokens.fontSizePageTitle
                font.bold: true
            }

            StackLayout {
                id: pageStack
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: tabBar.currentIndex

                ConnectionPage { tokens: window.tokens }
                ButtonsPage { tokens: window.tokens }
                StatisticsPage { tokens: window.tokens }
                PermissionsPage { tokens: window.tokens }
                DiagnosticsPage { tokens: window.tokens }
            }
        }
    }
}
