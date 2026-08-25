import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0
import "components"

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

    function diagnosticDetail(checkId) {
        var results = DiagnosticsController.checkResults
        for (var i = 0; i < results.length; i++) {
            if (results[i].checkId === checkId)
                return results[i].detail
        }
        return ""
    }

    readonly property bool rc003Detected:
        diagnosticStatus("raw_input") === "pass"
        && diagnosticStatus("ble_candidate") === "pass"
    readonly property string batteryText: {
        var status = diagnosticStatus("rc003_battery")
        if (status === "pass" || status === "manual" || status === "unsupported")
            return diagnosticDetail("rc003_battery")
        return DiagnosticsController.isRefreshing ? qsTr("正在检测…") : qsTr("尚未检测")
    }

    component DeviceStatusRow: ColumnLayout {
        required property string iconText
        required property color iconColor
        required property string titleText
        required property string detailText
        required property string statusText
        property bool positive: false
        property bool accent: false

        Layout.fillWidth: true
        spacing: tokens.spacingTiny

        RowLayout {
            Layout.fillWidth: true
            spacing: tokens.spacingSmall
            Label {
                Layout.preferredWidth: 22
                horizontalAlignment: Text.AlignHCenter
                text: parent.parent.iconText
                color: parent.parent.iconColor
                font.pixelSize: 20
                font.bold: true
            }
            Label {
                Layout.fillWidth: true
                text: parent.parent.titleText
                color: tokens.textPrimary
                font.pixelSize: tokens.fontSizeSmall
                font.bold: true
            }
            DsStatusPill {
                tokens: root.tokens
                labelText: parent.parent.statusText
                positive: parent.parent.positive
                accent: parent.parent.accent
            }
        }
        Label {
            Layout.fillWidth: true
            Layout.leftMargin: 22 + tokens.spacingSmall
            wrapMode: Text.WordWrap
            text: parent.detailText
            color: tokens.textSecondary
            font.pixelSize: tokens.fontSizeSmall
        }
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: ScrollBar.AsNeeded

        RowLayout {
            width: root.width - tokens.spacingLarge * 2
            x: tokens.spacingLarge
            y: tokens.spacingSmall
            spacing: tokens.spacingMedium

            DsCard {
                tokens: root.tokens
                Layout.preferredWidth: 330
                Layout.fillHeight: true
                Layout.minimumHeight: 680
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingSmall

                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: SettingsController.isRc003Device
                            ? qsTr("小米蓝牙遥控器 2 Pro")
                            : (SettingsController.isDjiMic2Device ? qsTr("DJI Mic 2") : qsTr("当前设备"))
                        color: tokens.textPrimary
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                    }
                    Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: qsTr("当前设备")
                        color: tokens.textSecondary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    ComboBox {
                        id: deviceCombo
                        objectName: "deviceCombo"
                        Layout.fillWidth: true
                        model: SettingsController.deviceOptions
                        currentIndex: SettingsController.selectedDeviceIndex
                        displayText: SettingsController.isRc003Device
                            ? qsTr("小米蓝牙遥控器 2 Pro")
                            : (SettingsController.isDjiMic2Device ? qsTr("DJI Mic 2") : currentText)
                        onActivated: SettingsController.selectedDeviceIndex = index
                        enabled: SettingsController.deviceCatalogAvailable
                        Accessible.name: qsTr("当前设备")
                    }
                    Label {
                        visible: !SettingsController.deviceCatalogAvailable
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: SettingsController.deviceCatalogErrorText
                        color: tokens.errorColor
                        font.pixelSize: tokens.fontSizeSmall
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 260
                        Image {
                            anchors.fill: parent
                            fillMode: Image.PreserveAspectFit
                            source: SettingsController.isRc003Device && SettingsController.photoAvailable
                                ? SettingsController.photoSource : ""
                            visible: source.toString().length > 0
                            smooth: true
                            asynchronous: true
                        }
                        Label {
                            anchors.centerIn: parent
                            visible: !SettingsController.isRc003Device || !SettingsController.photoAvailable
                            text: SettingsController.isDjiMic2Device ? qsTr("DJI Mic 2") : qsTr("遥控器图片不可用")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeTitle
                            font.bold: true
                        }
                    }

                    ColumnLayout {
                        visible: SettingsController.isRc003Device
                        Layout.fillWidth: true
                        spacing: 0

                        DeviceStatusRow {
                            iconText: root.rc003Detected ? "✓" : "○"
                            iconColor: root.rc003Detected ? tokens.successColor : tokens.textSecondary
                            titleText: qsTr("系统识别")
                            detailText: root.rc003Detected ? qsTr("Raw Input 与蓝牙已就绪") : qsTr("请到“检查”页重新检测")
                            statusText: root.rc003Detected ? qsTr("已就绪") : qsTr("待检查")
                            positive: root.rc003Detected
                        }
                        DsDivider { tokens: root.tokens }
                        DeviceStatusRow {
                            iconText: "▰"
                            iconColor: diagnosticStatus("rc003_battery") === "pass"
                                ? tokens.successColor : tokens.textSecondary
                            titleText: qsTr("遥控器电量")
                            detailText: qsTr("来自 Windows 设备状态")
                            statusText: root.batteryText
                            positive: diagnosticStatus("rc003_battery") === "pass"
                        }
                        DsDivider { tokens: root.tokens }
                        DeviceStatusRow {
                            iconText: SettingsController.activeVoicePresetConfirmed ? "●" : "○"
                            iconColor: SettingsController.activeVoicePresetConfirmed
                                ? tokens.accent : tokens.textSecondary
                            titleText: qsTr("语音桥接")
                            detailText: SettingsController.activeVoicePresetText
                            statusText: SettingsController.activeVoicePresetConfirmed
                                ? qsTr("当前预设") : qsTr("待确认")
                            accent: SettingsController.activeVoicePresetConfirmed
                        }
                    }

                    Item { Layout.fillHeight: true }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: tokens.spacingSmall
                        Button {
                            Layout.fillWidth: true
                            text: qsTr("恢复默认")
                            onClicked: SettingsController.restoreDefaults()
                        }
                        Button {
                            id: deviceSaveButton
                            objectName: "deviceSaveButton"
                            Layout.fillWidth: true
                            text: qsTr("保存选择")
                            highlighted: true
                            onClicked: SettingsController.saveSettings()
                        }
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: tokens.spacingMedium

                DsCard {
                    tokens: root.tokens
                    visible: SettingsController.isRc003Device
                    Layout.fillWidth: true
                    Layout.preferredHeight: 210
                    radius: tokens.cornerRadiusLarge
                    color: tokens.surface
                    border.color: tokens.border
                    border.width: 1
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: tokens.spacingLarge
                        spacing: tokens.spacingSmall
                        Label { text: qsTr("音频设置"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeTitle; font.bold: true }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("遥控器语音只写入所选虚拟音频设备，不改变 Windows 默认输入与输出。")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: tokens.spacingMedium
                            Label { text: qsTr("语音输出"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            ComboBox {
                                id: endpointCombo
                                objectName: "endpointCombo"
                                Layout.fillWidth: true
                                model: SettingsController.endpointOptions
                                currentIndex: SettingsController.selectedEndpointIndex
                                onActivated: SettingsController.selectedEndpointIndex = index
                                Accessible.name: qsTr("语音输出设备")
                            }
                        }
                        DsDivider { tokens: root.tokens }
                        RowLayout {
                            Layout.fillWidth: true
                            Label { text: qsTr("输出状态"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            DsStatusPill {
                                tokens: root.tokens
                                labelText: SettingsController.selectedEndpointIndex >= 0
                                    ? qsTr("已选择") : qsTr("未选择")
                                positive: SettingsController.selectedEndpointIndex >= 0
                            }
                            Label { Layout.fillWidth: true; text: qsTr("以“检查”页的实时检测结果为准"); color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                        }
                    }
                }

                DsCard {
                    tokens: root.tokens
                    visible: SettingsController.isRc003Device
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 385
                    radius: tokens.cornerRadiusLarge
                    color: tokens.surface
                    border.color: tokens.border
                    border.width: 1
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: tokens.spacingLarge
                        spacing: tokens.spacingSmall
                        Label { text: qsTr("语音软件"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeTitle; font.bold: true }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: qsTr("两个预设使用相同的按下点按开始、松开点按结束逻辑，只切换目标快捷键与必要适配。")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        GridLayout {
                            Layout.fillWidth: true
                            columns: 2
                            columnSpacing: tokens.spacingMedium
                            rowSpacing: tokens.spacingSmall
                            Label { text: qsTr("语音软件预设"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            ComboBox {
                                id: voicePresetCombo
                                objectName: "voicePresetCombo"
                                Layout.fillWidth: true
                                model: SettingsController.voicePresetOptions
                                currentIndex: SettingsController.voicePresetIndex
                                onActivated: SettingsController.voicePresetIndex = index
                                Accessible.name: qsTr("语音软件预设")
                            }
                            Label { text: qsTr("语音组合键"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeBody; font.bold: true }
                            TextField {
                                id: hotkeyField
                                objectName: "hotkeyField"
                                Layout.fillWidth: true
                                text: SettingsController.hotkeyText
                                selectByMouse: true
                                onEditingFinished: SettingsController.hotkeyText = text
                                Accessible.name: qsTr("语音热键")
                            }
                        }
                        Connections {
                            target: SettingsController
                            function onHotkeyTextChanged() { hotkeyField.text = SettingsController.hotkeyText }
                        }
                        DsDivider { tokens: root.tokens }
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: activePresetRow.implicitHeight + tokens.spacingMedium * 2
                            radius: tokens.cornerRadiusSmall
                            color: tokens.selectionBackground
                            RowLayout {
                                id: activePresetRow
                                anchors.fill: parent
                                anchors.margins: tokens.spacingMedium
                                spacing: tokens.spacingMedium
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Label { text: qsTr("当前生效预设"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeSmall; font.bold: true }
                                    Label { text: SettingsController.activeVoicePresetText; color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                                }
                                DsStatusPill {
                                    tokens: root.tokens
                                    labelText: SettingsController.activeVoicePresetConfirmed
                                        ? qsTr("已生效") : qsTr("待确认")
                                    positive: SettingsController.activeVoicePresetConfirmed
                                }
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: SettingsController.launchStatusText
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        RowLayout {
                            spacing: tokens.spacingSmall
                            Button {
                                id: saveAndLaunchButton
                                text: qsTr("保存并切换桥接")
                                highlighted: true
                                onClicked: SettingsController.saveAndLaunch()
                                KeyNavigation.tab: openLogButton
                            }
                            Button {
                                id: openLogButton
                                objectName: "openLogButton"
                                text: qsTr("打开日志目录")
                                onClicked: SettingsController.openLogLocation()
                            }
                        }
                        Item { Layout.fillHeight: true }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            visible: text.length > 0
                            text: SettingsController.errorMessage
                            color: tokens.errorColor
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            visible: text.length > 0 && SettingsController.errorMessage.length === 0
                            text: SettingsController.statusMessage
                            color: tokens.successColor
                            font.pixelSize: tokens.fontSizeSmall
                        }
                    }
                }

                Rectangle {
                    visible: SettingsController.isDjiMic2Device
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: tokens.cornerRadiusLarge
                    color: tokens.surface
                    border.color: tokens.border
                    border.width: 1
                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: tokens.spacingLarge
                        spacing: tokens.spacingMedium
                        Label { text: qsTr("DJI Mic 2 录音输入"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeTitle; font.bold: true }
                        Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: SettingsController.djiMicStatusText; color: tokens.textSecondary; font.pixelSize: tokens.fontSizeBody }
                        Label { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: qsTr("DJI Mic 2 使用 Windows 系统录音输入，不启动 RC003 桥接，也不会修改默认输入设备。"); color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                        RowLayout {
                            spacing: tokens.spacingSmall
                            Button { text: qsTr("重新检测"); onClicked: SettingsController.refreshDjiMicStatus() }
                            Button { text: qsTr("打开声音输入设置"); highlighted: true; onClicked: SettingsController.openSoundSettings() }
                        }
                        Item { Layout.fillHeight: true }
                    }
                }
            }
        }
    }
}
