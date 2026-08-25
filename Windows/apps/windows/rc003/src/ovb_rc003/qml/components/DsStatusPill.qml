import QtQuick
import QtQuick.Controls

Rectangle {
    id: root
    required property var tokens
    required property string labelText
    property bool positive: false
    property bool accent: false

    implicitWidth: pillLabel.implicitWidth + 20
    implicitHeight: pillLabel.implicitHeight + 10
    radius: 999
    color: positive ? tokens.successBackground
        : (accent ? tokens.selectionBackground : tokens.fieldBackground)

    Label {
        id: pillLabel
        anchors.centerIn: parent
        text: root.labelText
        color: root.positive ? tokens.successColor
            : (root.accent ? tokens.accent : tokens.textPrimary)
        font.pixelSize: tokens.fontSizeSmall
        font.bold: true
    }
}
