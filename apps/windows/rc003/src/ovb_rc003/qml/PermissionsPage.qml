// "权限" tab (XRBM-030 In-scope item 6): Windows' real permission surfaces
// for this app - Bluetooth pairing, microphone/speech recognition (Win+H
// dictation depends on it), and log-directory diagnostics. This page never
// renders a fabricated "已授权" state: Windows does not expose a single API
// this app can query for all of these states, so every row only offers to OPEN
// the relevant Settings page/log folder and states plainly what it is for.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: root.width - tokens.spacingLarge * 2
            x: tokens.spacingLarge
            y: tokens.spacingLarge
            spacing: tokens.spacingLarge

            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: permissionsColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: permissionsColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingLarge

                    Label {
                        text: qsTr("所需权限")
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                        color: tokens.textPrimary
                    }

                    // -- Bluetooth --------------------------------------------
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: tokens.spacingMedium
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                text: qsTr("蓝牙")
                                color: tokens.textPrimary
                                font.pixelSize: tokens.fontSizeBody
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("配对并连接 RC003，读取 ATVV 语音服务。配对本身在 Windows"
                                    + " 蓝牙设置里完成（见 README「配对 RC003」一节）。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        Button {
                            text: qsTr("打开蓝牙设置")
                            onClicked: SettingsController.openBluetoothSettings()
                        }
                    }

                    // -- Microphone / speech recognition ----------------------
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: tokens.spacingMedium
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label {
                                text: qsTr("麦克风与语音识别")
                                color: tokens.textPrimary
                                font.pixelSize: tokens.fontSizeBody
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("遥控器的语音键通过合成 Win+H 触发 Windows 自带的联机语音"
                                    + "听写；这需要 Windows「语音识别」已启用，以及系统麦克风输入选择"
                                    + "正确的设备（例如 VB-CABLE 的 CABLE Output）。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        ColumnLayout {
                            spacing: tokens.spacingTiny
                            Button {
                                text: qsTr("打开麦克风隐私设置")
                                onClicked: SettingsController.openMicrophonePrivacySettings()
                            }
                            Button {
                                text: qsTr("打开语音识别设置")
                                onClicked: SettingsController.openSpeechSettings()
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: diagnosticsColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: diagnosticsColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("诊断")
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    RowLayout {
                        spacing: tokens.spacingMedium
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("日志不记录语音内容、蓝牙地址或外设标识符（见"
                                + " tests/test_privacy_contract.py）。")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        Button {
                            text: qsTr("打开日志目录")
                            onClicked: SettingsController.openLogLocation()
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                        text: SettingsController.statusMessage
                        color: tokens.successColor
                        font.pixelSize: tokens.fontSizeSmall
                    }
                }
            }

            Item { Layout.preferredHeight: tokens.spacingLarge }
        }
    }
}
