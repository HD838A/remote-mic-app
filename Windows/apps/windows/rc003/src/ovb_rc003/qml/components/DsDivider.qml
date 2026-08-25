import QtQuick
import QtQuick.Layouts

Rectangle {
    required property var tokens
    Layout.fillWidth: true
    implicitHeight: 1
    color: tokens.border
}
