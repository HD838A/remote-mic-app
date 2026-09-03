// "检查与修复" tab (XRBM-031 In-scope items 1/4/5/6): a fourth top-level page
// that groups every windows_diagnostics.py check into distinct categories:
// ordinary buttons, RC003 voice, external microphones, Windows dictation,
// and the optional third-party driver state. It never lets pairing alone look
// like proof that buttons or speech actually work. DiagnosticsController
// runs every check off the Qt GUI thread (see qt_settings_app.py's module
// docstring), so "重新检测" never freezes this window.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens

    // Stable ids from windows_diagnostics.py's CheckGroup enum.
    readonly property string groupOrdinaryButtons: "ordinary_buttons"
    readonly property string groupVoiceBridge: "voice_bridge"
    readonly property string groupDictation: "dictation"
    readonly property string groupOptionalDriver: "optional_driver"
    readonly property string groupExternalMicrophone: "external_microphone"

    function rowsForGroup(groupId) {
        var rows = []
        var results = DiagnosticsController.checkResults
        for (var i = 0; i < results.length; i++) {
            if (results[i].group === groupId) {
                rows.push(results[i])
            }
        }
        return rows
    }

    function statusColor(status) {
        if (status === "pass") return tokens.successColor
        if (status === "fail") return tokens.errorColor
        if (status === "manual") return tokens.voiceAccent
        return tokens.textPrimary // "unsupported"
    }

    function statusLabel(status) {
        if (status === "pass") return qsTr("正常")
        if (status === "fail") return qsTr("未通过")
        if (status === "manual") return qsTr("待手动验证")
        return qsTr("不支持/不可用")
    }

    // Every diagnostic result uses the same two-line structure. Keeping the
    // title and the potentially long status copy in separate layout rows
    // prevents them from competing for width or painting over each other at
    // large Windows text/DPI scales.
    component DiagnosticResultItem: ColumnLayout {
        required property var modelData

        Layout.fillWidth: true
        spacing: tokens.spacingTiny

        RowLayout {
            Layout.fillWidth: true
            spacing: tokens.spacingSmall

            Rectangle {
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 10
                implicitHeight: 10
                radius: 5
                color: root.statusColor(modelData.status)
            }
            Label {
                Layout.fillWidth: true
                text: modelData.title
                color: tokens.textPrimary
                font.pixelSize: tokens.fontSizeSmall
                font.weight: Font.Normal
            }
        }
        Label {
            Layout.fillWidth: true
            Layout.leftMargin: 10 + tokens.spacingSmall
            Layout.preferredHeight: implicitHeight
            wrapMode: Text.WordWrap
            text: root.statusLabel(modelData.status) + " — " + modelData.detail
            color: tokens.textPrimary
            font.pixelSize: tokens.fontSizeSmall
            font.weight: Font.Normal
        }
    }

    Dialog {
        id: driverConfirmDialog
        objectName: "driverConfirmDialog"
        title: qsTr("启动 VB-CABLE 官方安装程序？")
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: DiagnosticsController.launchVbCableSetup()

        Label {
            width: 360
            wrapMode: Text.WordWrap
            text: qsTr("即将启动 VB-Audio 官方 VB-CABLE 安装程序（VBCABLE_Setup_x64.exe），"
                + "会弹出 Windows 用户账户控制 (UAC) 提示请求管理员权限——本程序自身不会以管理员"
                + "身份运行。VB-CABLE 是独立的 Donationware（非 GPL 项目代码），来自 VB-Audio，"
                + "见 https://www.vb-cable.com；仅随包提供基础版，不包含付费的 A+B / C+D。"
                + "安装后需要重启电脑，安装/卸载过程都会改变系统状态。确定要继续吗？")
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

            // -- Header / refresh -------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: diagnosticsHeader.implicitHeight + tokens.spacingLarge * 2
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1

                RowLayout {
                    id: diagnosticsHeader
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingMedium
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: tokens.spacingTiny
                        Label {
                            text: qsTr("系统检查")
                            font.pixelSize: tokens.fontSizeTitle
                            font.bold: true
                            color: tokens.textPrimary
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("检查设备、按键、蓝牙与语音链路。结果只代表对应项目，不用“进程运行”冒充“设备已连接”。")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                    }
                    BusyIndicator {
                        id: refreshBusyIndicator
                        objectName: "refreshBusyIndicator"
                        running: DiagnosticsController.isRefreshing
                        visible: running
                        implicitWidth: 20
                        implicitHeight: 20
                    }
                    Button {
                        id: refreshButton
                        objectName: "refreshButton"
                        text: qsTr("重新检测")
                        highlighted: true
                        enabled: !DiagnosticsController.isRefreshing
                        onClicked: DiagnosticsController.refreshDiagnostics()
                    }
                }
            }

            // Prominent, page-level error (XRBM-031 RETRY 1 item 2): shown
            // right under the intro text - NOT only as a driver-card
            // message below the fold - whenever the background diagnostics
            // run itself failed unexpectedly, so a user is never left
            // looking at a blank/stale-looking page with no explanation.
            Rectangle {
                id: diagnosticsErrorBanner
                objectName: "diagnosticsErrorBanner"
                Layout.fillWidth: true
                visible: DiagnosticsController.diagnosticsErrorMessage.length > 0
                radius: tokens.cornerRadiusSmall
                color: Qt.rgba(tokens.errorColor.r, tokens.errorColor.g, tokens.errorColor.b, 0.12)
                border.color: tokens.errorColor
                border.width: 1
                implicitHeight: diagnosticsErrorLabel.implicitHeight + tokens.spacingMedium * 2

                Label {
                    id: diagnosticsErrorLabel
                    anchors.fill: parent
                    anchors.margins: tokens.spacingMedium
                    wrapMode: Text.WordWrap
                    text: DiagnosticsController.diagnosticsErrorMessage
                    color: tokens.errorColor
                    font.pixelSize: tokens.fontSizeSmall
                }
            }

            // -- Group: ordinary buttons -------------------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: ordinaryButtonsColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: ordinaryButtonsColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("普通按键前提")
                        font.pixelSize: tokens.fontSizeBody
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Repeater {
                        model: root.rowsForGroup(root.groupOrdinaryButtons)
                        delegate: DiagnosticResultItem {}
                    }
                }
            }

            // -- Group: RC003 voice bridge -----------------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: voiceBridgeColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: voiceBridgeColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("RC003 语音链路前提")
                        font.pixelSize: tokens.fontSizeBody
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Repeater {
                        model: root.rowsForGroup(root.groupVoiceBridge)
                        delegate: DiagnosticResultItem {}
                    }
                }
            }

            // -- Group: external microphone inputs ---------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: externalMicColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: externalMicColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("无线麦克风输入")
                        font.pixelSize: tokens.fontSizeBody
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.preferredHeight: implicitHeight
                        wrapMode: Text.WordWrap
                        text: qsTr("以系统录音端点为准；仅显示“已配对”不能证明麦克风当前可录音。")
                        color: tokens.textPrimary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    Repeater {
                        model: root.rowsForGroup(root.groupExternalMicrophone)
                        delegate: DiagnosticResultItem {}
                    }
                    Button {
                        text: qsTr("打开 Windows 声音输入设置")
                        onClicked: SettingsController.openSoundSettings()
                    }
                }
            }

            // -- Group: Windows dictation (always manual) --------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: dictationColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: dictationColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("Windows 听写前提")
                        font.pixelSize: tokens.fontSizeBody
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Repeater {
                        model: root.rowsForGroup(root.groupDictation)
                        delegate: DiagnosticResultItem {}
                    }
                    RowLayout {
                        spacing: tokens.spacingSmall
                        Button {
                            text: qsTr("打开语音识别设置")
                            onClicked: SettingsController.openSpeechSettings()
                        }
                        Button {
                            text: qsTr("打开麦克风隐私设置")
                            onClicked: SettingsController.openMicrophonePrivacySettings()
                        }
                    }
                }
            }

            // -- Group: optional VB-CABLE driver ------------------------------
            Rectangle {
                Layout.fillWidth: true
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1
                implicitHeight: driverColumn.implicitHeight + tokens.spacingLarge * 2

                ColumnLayout {
                    id: driverColumn
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        text: qsTr("可选：VB-CABLE 虚拟音频驱动")
                        font.pixelSize: tokens.fontSizeBody
                        font.bold: true
                        color: tokens.textPrimary
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.preferredHeight: implicitHeight
                        wrapMode: Text.WordWrap
                        text: qsTr("VB-CABLE by VB-Audio（https://www.vb-cable.com）——独立的 "
                            + "Donationware，不是本项目 GPL-3.0 代码的一部分，可自愿捐赠/购买授权。"
                            + "本页仅随包提供基础版（Basic）安装包，不包含付费的 A+B / C+D 版本。"
                            + "安装会改变系统状态、请求管理员权限，安装/卸载都需要重启；本程序"
                            + "从不修改 Windows 默认输入/输出设备。")
                        color: tokens.textPrimary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    Repeater {
                        model: root.rowsForGroup(root.groupOptionalDriver)
                        delegate: DiagnosticResultItem {}
                    }
                    RowLayout {
                        spacing: tokens.spacingSmall
                        Button {
                            id: selectCableInputButton
                            objectName: "selectCableInputButton"
                            text: qsTr("选择检测到的 CABLE Input 作为输出")
                            onClicked: DiagnosticsController.selectDetectedCableInputAsOutput()
                        }
                        Button {
                            id: launchDriverSetupButton
                            objectName: "launchDriverSetupButton"
                            text: qsTr("安装/修复 VB-CABLE…")
                            onClicked: driverConfirmDialog.open()
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.preferredHeight: implicitHeight
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                        text: DiagnosticsController.driverErrorMessage
                        color: tokens.errorColor
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.preferredHeight: implicitHeight
                        wrapMode: Text.WordWrap
                        visible: text.length > 0 && DiagnosticsController.driverErrorMessage.length === 0
                        text: DiagnosticsController.driverStatusMessage
                        color: tokens.successColor
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    // Neutral/informational outcome (XRBM-031 RETRY 1 item
                    // 7): a UAC cancellation or "vendor setup launched"
                    // notice - neither is a completed success, so neither
                    // ever renders in the success (green) color above.
                    Label {
                        id: driverInfoLabel
                        objectName: "driverInfoLabel"
                        Layout.fillWidth: true
                        Layout.preferredHeight: implicitHeight
                        wrapMode: Text.WordWrap
                        visible: text.length > 0
                            && DiagnosticsController.driverErrorMessage.length === 0
                            && DiagnosticsController.driverStatusMessage.length === 0
                        text: DiagnosticsController.driverInfoMessage
                        color: tokens.textPrimary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                }
            }

            // -- Shared open-settings / open-log actions ---------------------
            RowLayout {
                Layout.fillWidth: true
                spacing: tokens.spacingSmall
                Button {
                    text: qsTr("打开蓝牙设置")
                    onClicked: SettingsController.openBluetoothSettings()
                }
                Button {
                    text: qsTr("打开麦克风隐私设置")
                    onClicked: SettingsController.openMicrophonePrivacySettings()
                }
                Button {
                    text: qsTr("打开声音输入/输出设置")
                    onClicked: SettingsController.openSoundSettings()
                }
                Button {
                    id: openAppsSettingsButton
                    objectName: "openAppsSettingsButton"
                    text: qsTr("打开应用设置")
                    onClicked: SettingsController.openAppsSettings()
                }
                Button {
                    id: diagnosticsOpenLogButton
                    objectName: "diagnosticsOpenLogButton"
                    text: qsTr("打开日志目录")
                    onClicked: SettingsController.openLogLocation()
                }
            }

            Item { Layout.preferredHeight: tokens.spacingLarge }
        }
    }
}
