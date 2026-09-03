import QtQuick

Rectangle {
    required property var tokens
    radius: tokens.cornerRadiusLarge
    color: tokens.surface
    border.color: tokens.border
    border.width: 1
}
