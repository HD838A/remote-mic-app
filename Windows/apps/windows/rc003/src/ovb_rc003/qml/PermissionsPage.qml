import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens

    function diagnosticStatus(checkId) {
        var results = DiagnosticsController.checkResults
        for (var i = 0; i < results.length; i++) {
            if (results[i].checkId === checkId)
                return results[i].status
        }
        return ""
    }

    readonly property bool deviceDetected:
        diagnosticStatus("raw_input") === "pass"
        && diagnosticStatus("ble_candidate") === "pass"

    component StepBadge: Rectangle {
        required property string numberText
        implicitWidth: 30
        implicitHeight: 30
        radius: 15
        color: tokens.accent
        Label {
            anchors.centerIn: parent
            text: parent.numberText
            color: tokens.accentText
            font.pixelSize: tokens.fontSizeSmall
            font.bold: true
        }
    }

    component StatePill: Rectangle {
        required property string labelText
        property bool positive: false
        implicitWidth: pillText.implicitWidth + 20
        implicitHeight: pillText.implicitHeight + 10
        radius: 999
        color: positive ? tokens.successBackground : tokens.fieldBackground
        Label {
            id: pillText
            anchors.centerIn: parent
            text: parent.labelText
            color: parent.positive ? tokens.successColor : tokens.textPrimary
            font.pixelSize: tokens.fontSizeSmall
            font.bold: true
        }
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: root.width - tokens.spacingLarge * 2
            x: tokens.spacingLarge
            y: tokens.spacingSmall
            spacing: tokens.spacingMedium

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: permissionIntro.implicitHeight + tokens.spacingLarge * 2
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                ColumnLayout {
                    id: permissionIntro
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingTiny
                    Label {
                        text: qsTr("Windows 所需能力")
                        color: tokens.textPrimary
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("Windows 没有与 macOS 输入监控完全对应的统一授权页；这里按真实使用边界分别说明和跳转。")
                        color: tokens.textSecondary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: permissionRows.implicitHeight + tokens.spacingMedium * 2
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1

                ColumnLayout {
                    id: permissionRows
                    anchors.fill: parent
                    anchors.margins: tokens.spacingMedium
                    spacing: 0

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.minimumHeight: 96
                        spacing: tokens.spacingMedium
                        StepBadge { numberText: "1" }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { text: qsTr("蓝牙与设备连接"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("RC003 需先在 Windows 蓝牙设置中完成配对；Remote Mic 再读取 Raw Input、ATVV 语音服务和设备状态。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        StatePill { labelText: root.deviceDetected ? qsTr("已检测") : qsTr("需要检查"); positive: root.deviceDetected }
                        Button { text: qsTr("打开蓝牙设置"); onClicked: SettingsController.openBluetoothSettings() }
                    }

                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: tokens.border }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.minimumHeight: 106
                        spacing: tokens.spacingMedium
                        StepBadge { numberText: "2" }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { text: qsTr("语音软件的麦克风访问"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("Typeless 或千问需要被 Windows 允许使用麦克风，并在软件内选择 CABLE Output。Remote Mic 不采集电脑麦克风。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        StatePill { labelText: qsTr("由目标软件决定") }
                        ColumnLayout {
                            spacing: tokens.spacingTiny
                            Button { text: qsTr("麦克风隐私设置"); onClicked: SettingsController.openMicrophonePrivacySettings() }
                            Button { text: qsTr("语音识别设置"); onClicked: SettingsController.openSpeechSettings() }
                        }
                    }

                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: tokens.border }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.minimumHeight: 92
                        spacing: tokens.spacingMedium
                        StepBadge { numberText: "3" }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2
                            Label { text: qsTr("管理员权限"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("日常桥接不依赖管理员权限；仅安装 VB-CABLE 或执行特定修复时可能触发 Windows 管理员确认。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        StatePill { labelText: qsTr("日常无需"); positive: true }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: privacyColumn.implicitHeight + tokens.spacingLarge * 2
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                ColumnLayout {
                    id: privacyColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall
                    Label { text: qsTr("诊断与隐私"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeTitle; font.bold: true }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: tokens.spacingMedium
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("应用日志不记录语音内容、蓝牙地址或设备路径；具体结果请到“检查”页逐项确认。")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        Button { text: qsTr("打开日志目录"); onClicked: SettingsController.openLogLocation() }
                        Button { text: qsTr("打开应用设置"); onClicked: SettingsController.openAppsSettings() }
                    }
                }
            }

            Item { Layout.preferredHeight: tokens.spacingMedium }
        }
    }
}
