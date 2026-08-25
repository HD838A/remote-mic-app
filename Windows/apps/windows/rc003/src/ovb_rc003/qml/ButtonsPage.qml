import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens
    readonly property real photoAspectRatio: 1536 / 1024

    function openShortcutRecorder(buttonId, rowIndex, isMic, trigger) {
        shortcutRecorder.buttonId = buttonId
        shortcutRecorder.rowIndex = rowIndex
        shortcutRecorder.isMic = isMic
        shortcutRecorder.trigger = trigger || "single_click"
        shortcutRecorder.previewText = qsTr("请按下要映射的真实按键")
        shortcutRecorder.open()
    }

    Dialog {
        id: shortcutRecorder
        objectName: "shortcutRecorderDialog"
        modal: true
        anchors.centerIn: parent
        width: 430
        title: qsTr("录制自定义快捷键")
        standardButtons: Dialog.Cancel
        property string buttonId: ""
        property int rowIndex: -1
        property bool isMic: false
        property string trigger: "single_click"
        property string previewText: ""

        function commitShortcut(chord) {
            previewText = chord
            if (isMic)
                SettingsController.hotkeyText = chord
            else if (trigger === "single_click")
                ButtonMappingModel.setActionTextAt(rowIndex, chord)
            else
                ButtonMappingModel.setSecondaryActionTextAt(rowIndex, trigger, chord)
            close()
        }

        onOpened: {
            captureArea.forceActiveFocus()
            SettingsController.startHotkeyCapture()
        }
        onClosed: SettingsController.stopHotkeyCapture()

        Connections {
            target: SettingsController
            function onHotkeyCaptured(chord) {
                if (shortcutRecorder.visible)
                    shortcutRecorder.commitShortcut(chord)
            }
            function onHotkeyCaptureError(message) {
                if (shortcutRecorder.visible)
                    shortcutRecorder.previewText = message
            }
        }

        contentItem: FocusScope {
            id: captureArea
            implicitHeight: 150
            focus: true
            ColumnLayout {
                anchors.fill: parent
                spacing: tokens.spacingMedium
                Label {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: shortcutRecorder.previewText
                    font.pixelSize: tokens.fontSizeTitle
                    color: tokens.accent
                }
                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    text: qsTr("直接按下要映射的真实按键；左右修饰键会分别记录，录制期间不会执行快捷键。")
                    color: tokens.textSecondary
                    font.pixelSize: tokens.fontSizeSmall
                }
            }
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

            RowLayout {
                Layout.fillWidth: true
                spacing: tokens.spacingSmall
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: tokens.spacingTiny
                    Label { text: qsTr("按键动作"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeTitle; font.bold: true }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("点击遥控器实物位置或右侧映射行进行定位，修改后手动保存。")
                        color: tokens.textSecondary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                }
                Button {
                    id: detectRealKeyButton
                    objectName: "detectRealKeyButton"
                    text: SettingsController.keyDetectionActive ? qsTr("停止检测") : qsTr("检测真实按键")
                    highlighted: SettingsController.keyDetectionActive
                    onClicked: SettingsController.keyDetectionActive
                        ? SettingsController.stopKeyDetection() : SettingsController.startKeyDetection()
                }
                Button { text: qsTr("恢复默认"); onClicked: SettingsController.restoreDefaults() }
                Button {
                    id: saveMappingButton
                    objectName: "saveMappingButton"
                    text: qsTr("保存映射")
                    highlighted: true
                    onClicked: SettingsController.saveSettings()
                }
            }

            Rectangle {
                Layout.fillWidth: true
                visible: SettingsController.keyDetectionActive || SettingsController.keyDetectionText.length > 0
                implicitHeight: detectionText.implicitHeight + tokens.spacingMedium * 2
                radius: tokens.cornerRadiusSmall
                color: tokens.fieldBackground
                border.color: SettingsController.keyDetectionActive ? tokens.accent : tokens.border
                border.width: SettingsController.keyDetectionActive ? 2 : 1
                Label {
                    id: detectionText
                    anchors.fill: parent
                    anchors.margins: tokens.spacingMedium
                    wrapMode: Text.WordWrap
                    text: SettingsController.keyDetectionText
                    color: SettingsController.keyDetectionActive ? tokens.accent : tokens.textSecondary
                    font.pixelSize: tokens.fontSizeSmall
                }
            }

            RowLayout {
                id: rc003MappingLayout
                objectName: "rc003MappingLayout"
                visible: SettingsController.isRc003Device
                Layout.fillWidth: true
                Layout.preferredHeight: 580
                spacing: tokens.spacingMedium

                Rectangle {
                    Layout.preferredWidth: 280
                    Layout.fillHeight: true
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
                            text: qsTr("遥控器定位")
                            color: tokens.textPrimary
                            font.pixelSize: tokens.fontSizeTitle
                            font.bold: true
                        }
                        Label {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: qsTr("当前选中：") + SettingsController.selectedButtonDisplayName
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }

                        Item {
                            id: photoFrame
                            Layout.preferredWidth: 220
                            Layout.preferredHeight: 390
                            Layout.alignment: Qt.AlignHCenter

                            Image {
                                id: photoImage
                                objectName: "photoImage"
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectFit
                                source: SettingsController.photoAvailable ? SettingsController.photoSource : ""
                                visible: SettingsController.photoAvailable
                                smooth: true
                                asynchronous: true
                            }
                            Label {
                                anchors.centerIn: parent
                                visible: !SettingsController.photoAvailable
                                text: qsTr("实物图资源缺失")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                            Repeater {
                                model: ButtonMappingModel
                                delegate: Item {
                                    id: hotspot
                                    objectName: "photoHotspot_" + buttonId
                                    required property string buttonId
                                    required property string displayName
                                    required property real hotspotX
                                    required property real hotspotY
                                    required property real hotspotWidth
                                    required property real hotspotHeight
                                    required property bool isSelected
                                    required property bool isVoice
                                    readonly property real paintedW: photoImage.paintedWidth
                                    readonly property real paintedH: photoImage.paintedHeight
                                    readonly property real offsetX: photoImage.x + (photoImage.width - paintedW) / 2
                                    readonly property real offsetY: photoImage.y + (photoImage.height - paintedH) / 2
                                    width: hotspotWidth * paintedW
                                    height: hotspotHeight * paintedH
                                    x: offsetX + hotspotX * paintedW - width / 2
                                    y: offsetY + hotspotY * paintedH - height / 2
                                    visible: SettingsController.photoAvailable
                                    activeFocusOnTab: true
                                    Accessible.role: Accessible.Button
                                    Accessible.name: displayName
                                    Rectangle {
                                        anchors.fill: parent
                                        radius: height / 2
                                        color: hotspot.isSelected
                                            ? Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.28)
                                            : (hoverHandler.hovered
                                                ? Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.14)
                                                : "transparent")
                                        border.width: hotspot.isSelected ? 2 : (hotspot.activeFocus ? 1 : 0)
                                        border.color: hotspot.isVoice ? tokens.voiceAccent : tokens.accent
                                    }
                                    HoverHandler { id: hoverHandler }
                                    TapHandler { onTapped: SettingsController.selectButton(hotspot.buttonId) }
                                    Keys.onReturnPressed: SettingsController.selectButton(hotspot.buttonId)
                                    Keys.onSpacePressed: SettingsController.selectButton(hotspot.buttonId)
                                }
                            }
                        }
                        Label {
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            horizontalAlignment: Text.AlignHCenter
                            text: qsTr("返回键与音量键能否映射，以“检测真实按键”的完整按下/松开结果为准。")
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    radius: tokens.cornerRadiusLarge
                    color: tokens.surface
                    border.color: tokens.border
                    border.width: 1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: tokens.spacingLarge
                        spacing: tokens.spacingSmall
                        Label { text: qsTr("实际按键映射"); color: tokens.textPrimary; font.pixelSize: tokens.fontSizeTitle; font.bold: true }

                        GridView {
                            id: mappingList
                            objectName: "mappingList"
                            Layout.fillWidth: true
                            Layout.preferredHeight: 402
                            clip: true
                            model: ButtonMappingModel
                            cellWidth: Math.floor(width / 2)
                            cellHeight: 57
                            currentIndex: ButtonMappingModel.indexOfButton(SettingsController.selectedButtonId)
                            onCurrentIndexChanged: positionViewAtIndex(currentIndex, GridView.Contain)

                            delegate: Rectangle {
                                id: mappingRow
                                required property int index
                                required property string buttonId
                                required property string displayName
                                required property string hidUsage
                                required property string actionText
                                required property string doubleClickText
                                required property string longPressText
                                required property bool isMic
                                required property bool isSelected
                                width: mappingList.cellWidth - tokens.spacingSmall
                                height: mappingList.cellHeight - 2
                                radius: tokens.cornerRadiusSmall
                                color: isSelected ? tokens.selectionBackground : "transparent"

                                onActionTextChanged: if (!isMic && actionCombo._initialized) actionCombo.editText = actionText
                                HoverHandler { id: mappingRowHover }
                                TapHandler { onTapped: SettingsController.selectButton(mappingRow.buttonId) }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: tokens.spacingSmall
                                    anchors.rightMargin: tokens.spacingSmall
                                    spacing: tokens.spacingSmall
                                    Label {
                                        Layout.preferredWidth: 76
                                        text: mappingRow.displayName
                                        color: tokens.textPrimary
                                        font.pixelSize: tokens.fontSizeSmall
                                        font.bold: true
                                    }
                                    ComboBox {
                                        id: actionCombo
                                        objectName: "actionCombo_" + mappingRow.buttonId
                                        visible: !mappingRow.isMic
                                        Layout.fillWidth: true
                                        editable: true
                                        model: SettingsController.presetActionOptions
                                        property bool _initialized: false
                                        Component.onCompleted: {
                                            editText = mappingRow.actionText
                                            _initialized = true
                                        }
                                        onEditTextChanged: if (_initialized) ButtonMappingModel.setActionTextAt(mappingRow.index, editText)
                                        onAccepted: ButtonMappingModel.setActionTextAt(mappingRow.index, editText)
                                        onActivated: ButtonMappingModel.setActionTextAt(mappingRow.index, currentText)
                                    }
                                    TextField {
                                        id: voiceHotkeyField
                                        objectName: "voiceHotkeyField_" + mappingRow.buttonId
                                        visible: mappingRow.isMic
                                        Layout.fillWidth: true
                                        text: SettingsController.hotkeyText
                                        selectByMouse: true
                                        onEditingFinished: SettingsController.hotkeyText = text
                                    }
                                    Button {
                                        visible: mappingRow.isSelected || mappingRowHover.hovered
                                        text: qsTr("录")
                                        Layout.preferredWidth: visible ? 30 : 0
                                        onClicked: root.openShortcutRecorder(mappingRow.buttonId, mappingRow.index, mappingRow.isMic, "single_click")
                                    }
                                    Label {
                                        visible: mappingRow.buttonId === "back"
                                            || mappingRow.buttonId === "volume_up"
                                            || mappingRow.buttonId === "volume_down"
                                        text: qsTr("待")
                                        color: tokens.voiceAccent
                                        font.pixelSize: tokens.fontSizeSmall
                                        font.bold: true
                                        ToolTip.visible: statusHover.hovered
                                        ToolTip.text: qsTr("待检测真实按键")
                                        HoverHandler { id: statusHover }
                                    }
                                }
                            }
                        }

                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: tokens.border }

                        Repeater {
                            model: ButtonMappingModel
                            delegate: ColumnLayout {
                                required property int index
                                required property string buttonId
                                required property string displayName
                                required property string doubleClickText
                                required property string longPressText
                                required property bool isMic
                                required property bool isSelected
                                visible: isSelected && !isMic
                                Layout.fillWidth: true
                                Layout.preferredHeight: visible ? implicitHeight : 0
                                spacing: tokens.spacingSmall
                                Label {
                                    text: displayName + qsTr("其他触发")
                                    color: tokens.textPrimary
                                    font.pixelSize: tokens.fontSizeSmall
                                    font.bold: true
                                }
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: tokens.spacingSmall
                                    Label { text: qsTr("双击"); color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                                    ComboBox {
                                        Layout.fillWidth: true
                                        editable: true
                                        model: SettingsController.secondaryActionOptions
                                        Component.onCompleted: editText = doubleClickText
                                        onAccepted: ButtonMappingModel.setSecondaryActionTextAt(index, "double_click", editText)
                                        onActivated: ButtonMappingModel.setSecondaryActionTextAt(index, "double_click", currentText)
                                    }
                                    Label { text: qsTr("长按"); color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                                    ComboBox {
                                        Layout.fillWidth: true
                                        editable: true
                                        model: SettingsController.secondaryActionOptions
                                        Component.onCompleted: editText = longPressText
                                        onAccepted: ButtonMappingModel.setSecondaryActionTextAt(index, "long_press", editText)
                                        onActivated: ButtonMappingModel.setSecondaryActionTextAt(index, "long_press", currentText)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: djiControlLayout
                objectName: "djiControlLayout"
                visible: !SettingsController.isRc003Device
                Layout.fillWidth: true
                Layout.preferredHeight: visible ? djiControlsColumn.implicitHeight + tokens.spacingLarge * 2 : 0
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1

                ColumnLayout {
                    id: djiControlsColumn
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingMedium

                    Label {
                        text: qsTr("DJI Mic 2 设备控制")
                        color: tokens.textPrimary
                        font.pixelSize: tokens.fontSizeTitle
                        font.bold: true
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        text: qsTr("该设备使用 Windows 系统录音输入；下列硬件控制按实际设备能力展示，不启动 RC003 桥接。")
                        color: tokens.textSecondary
                        font.pixelSize: tokens.fontSizeSmall
                    }
                    Repeater {
                        model: SettingsController.djiControlRows
                        delegate: Rectangle {
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: djiRow.implicitHeight + tokens.spacingMedium * 2
                            radius: tokens.cornerRadiusSmall
                            color: tokens.fieldBackground
                            RowLayout {
                                id: djiRow
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: tokens.spacingMedium
                                anchors.rightMargin: tokens.spacingMedium
                                spacing: tokens.spacingMedium
                                Label {
                                    Layout.preferredWidth: 100
                                    text: modelData.name
                                    color: tokens.textPrimary
                                    font.bold: true
                                }
                                Label {
                                    Layout.fillWidth: true
                                    text: modelData.behavior
                                    color: tokens.textSecondary
                                    wrapMode: Text.WordWrap
                                }
                                Label {
                                    Layout.preferredWidth: 240
                                    text: modelData.mapping
                                    color: tokens.accent
                                    wrapMode: Text.WordWrap
                                }
                            }
                        }
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                visible: SettingsController.errorMessage.length > 0
                wrapMode: Text.WordWrap
                text: SettingsController.errorMessage
                color: tokens.errorColor
                font.pixelSize: tokens.fontSizeSmall
            }
            Label {
                Layout.fillWidth: true
                visible: SettingsController.errorMessage.length === 0 && SettingsController.statusMessage.length > 0
                wrapMode: Text.WordWrap
                text: SettingsController.statusMessage
                color: tokens.successColor
                font.pixelSize: tokens.fontSizeSmall
            }

            Item { Layout.preferredHeight: tokens.spacingMedium }
        }
    }
}
