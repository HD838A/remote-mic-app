import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import OvbRc003Settings 1.0

Item {
    id: root
    property var tokens
    property int selectedMetric: 0

    readonly property int cellWidth: 16
    readonly property int cellHeight: 20
    readonly property int cellGap: 5
    readonly property int columnPitch: cellWidth + cellGap
    readonly property int rowPitch: cellHeight + cellGap
    readonly property int monthLabelHeight: 28

    function heatColor(level, future) {
        if (future) return Qt.rgba(tokens.textPrimary.r, tokens.textPrimary.g, tokens.textPrimary.b, 0.025)
        if (level <= 0) return tokens.heatmapEmpty
        if (level === 1) return Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.24)
        if (level === 2) return Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.45)
        if (level === 3) return Qt.rgba(tokens.accent.r, tokens.accent.g, tokens.accent.b, 0.70)
        return tokens.accent
    }

    function alignCurrentMonth() {
        Qt.callLater(function() {
            var current = monthRepeater.itemAt(UsageStatisticsController.currentMonthIndex)
            if (current)
                monthFlick.contentX = Math.max(0, current.x)
        })
    }

    onVisibleChanged: {
        if (visible) {
            UsageStatisticsController.refresh()
            alignCurrentMonth()
        }
    }

    Connections {
        target: UsageStatisticsController
        function onStatisticsChanged() { root.alignCurrentMonth() }
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
                spacing: tokens.spacingMedium
                Repeater {
                    model: [
                        { label: qsTr("今日语音时长"), value: UsageStatisticsController.todayDuration },
                        { label: qsTr("今日触发次数"), value: UsageStatisticsController.todayFrequency },
                        { label: qsTr("本年活跃"), value: UsageStatisticsController.activeDays }
                    ]
                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 100
                        radius: tokens.cornerRadiusLarge
                        color: tokens.surface
                        border.color: tokens.border
                        border.width: 1
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: tokens.spacingMedium
                            spacing: tokens.spacingTiny
                            Label {
                                text: modelData.label
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                            Label {
                                text: modelData.value
                                color: tokens.accent
                                font.pixelSize: 24
                                font.bold: true
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 360
                radius: tokens.cornerRadiusLarge
                color: tokens.surface
                border.color: tokens.border
                border.width: 1

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: tokens.spacingLarge
                    spacing: tokens.spacingMedium

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: tokens.spacingMedium
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: tokens.spacingTiny
                            Label {
                                text: UsageStatisticsController.yearLabel + qsTr(" 年使用")
                                color: tokens.textPrimary
                                font.pixelSize: tokens.fontSizeTitle
                                font.bold: true
                            }
                            Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                text: qsTr("横轴为 1 月至 12 月；可左右滑动，进入页面时当前月份位于最左侧。纵轴严格对应周一至周日。")
                                color: tokens.textSecondary
                                font.pixelSize: tokens.fontSizeSmall
                            }
                        }
                        Button {
                            text: qsTr("语音时长")
                            checkable: true
                            checked: root.selectedMetric === 0
                            highlighted: checked
                            onClicked: root.selectedMetric = 0
                        }
                        Button {
                            text: qsTr("触发次数")
                            checkable: true
                            checked: root.selectedMetric === 1
                            highlighted: checked
                            onClicked: root.selectedMetric = 1
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Layout.preferredHeight: root.monthLabelHeight + root.rowPitch * 6 + root.cellHeight
                        spacing: tokens.spacingSmall

                        Column {
                            Layout.preferredWidth: 58
                            Layout.fillHeight: true
                            spacing: root.cellGap
                            Item { width: 1; height: root.monthLabelHeight - root.cellGap }
                            Repeater {
                                model: [qsTr("周一"), qsTr("周二"), qsTr("周三"), qsTr("周四"), qsTr("周五"), qsTr("周六"), qsTr("周日")]
                                delegate: Label {
                                    width: 58
                                    height: root.cellHeight
                                    verticalAlignment: Text.AlignVCenter
                                    text: modelData
                                    color: tokens.textSecondary
                                    font.pixelSize: tokens.fontSizeSmall
                                }
                            }
                        }

                        Flickable {
                            id: monthFlick
                            objectName: "statisticsMonthFlick"
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            flickableDirection: Flickable.HorizontalFlick
                            boundsBehavior: Flickable.StopAtBounds
                            contentWidth: yearRow.width
                            contentHeight: height

                            ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                            Row {
                                id: yearRow
                                height: parent.height
                                spacing: 30

                                Repeater {
                                    id: monthRepeater
                                    model: UsageStatisticsController.monthBlocks
                                    delegate: Item {
                                        id: monthBlock
                                        required property var modelData
                                        width: modelData.weekCount * root.columnPitch - root.cellGap
                                        height: yearRow.height

                                        Label {
                                            height: root.monthLabelHeight
                                            text: monthBlock.modelData.label
                                            verticalAlignment: Text.AlignTop
                                            color: tokens.textPrimary
                                            font.pixelSize: tokens.fontSizeSmall
                                            font.bold: true
                                        }

                                        Repeater {
                                            model: monthBlock.modelData.cells
                                            delegate: Rectangle {
                                                required property var modelData
                                                x: modelData.weekIndex * root.columnPitch
                                                y: root.monthLabelHeight + modelData.dayIndex * root.rowPitch
                                                width: root.cellWidth
                                                height: root.cellHeight
                                                radius: 3
                                                color: root.heatColor(
                                                    root.selectedMetric === 0 ? modelData.durationLevel : modelData.frequencyLevel,
                                                    modelData.isFuture
                                                )
                                                border.color: Qt.rgba(tokens.textPrimary.r, tokens.textPrimary.g, tokens.textPrimary.b, 0.07)
                                                border.width: 1
                                                ToolTip.visible: hover.containsMouse && !modelData.isFuture
                                                ToolTip.text: modelData.date + " · "
                                                    + (root.selectedMetric === 0 ? modelData.durationText : modelData.frequencyText)
                                                MouseArea { id: hover; anchors.fill: parent; hoverEnabled: true }
                                            }
                                        }
                                    }
                                }

                                Item {
                                    width: Math.max(0, monthFlick.width - 80)
                                    height: 1
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Label {
                            Layout.fillWidth: true
                            text: UsageStatisticsController.rangeText
                            color: tokens.textSecondary
                            font.pixelSize: tokens.fontSizeSmall
                        }
                        Label { text: qsTr("少"); color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                        Repeater {
                            model: 5
                            delegate: Rectangle {
                                width: 14
                                height: 14
                                radius: 3
                                color: root.heatColor(index, false)
                                border.color: tokens.border
                            }
                        }
                        Label { text: qsTr("多"); color: tokens.textSecondary; font.pixelSize: tokens.fontSizeSmall }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: privacyText.implicitHeight + tokens.spacingMedium * 2
                radius: tokens.cornerRadiusSmall
                color: tokens.fieldBackground
                Label {
                    id: privacyText
                    anchors.fill: parent
                    anchors.margins: tokens.spacingMedium
                    wrapMode: Text.WordWrap
                    text: qsTr("隐私说明：只保存每天累计的按键次数、语音会话次数和语音时长；不保存音频、转写文字、应用名称或设备标识。")
                    color: tokens.textSecondary
                    font.pixelSize: tokens.fontSizeSmall
                }
            }

            Item { Layout.preferredHeight: tokens.spacingMedium }
        }
    }
}
