// MessageBubble — balão de mensagem (entrada à esquerda, saída à direita).
//
// Cores/raios vêm dos tokens do shell; cantos inferiores assimétricos marcam o
// lado do remetente. Tipos não-texto (mídia futura) aparecem como rótulo com
// ícone. Timestamps são strings de milissegundos — usados só para formatar.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    property string messageId: ""
    property string chat: ""
    property string sender: ""
    property bool fromMe: false
    property string timestamp: ""
    property string type: "text"
    property string text: ""
    property string quotedId: ""
    property bool edited: false
    property bool deleted: false
    property string status: ""

    readonly property bool isText: root.type === "text" || root.type === "protocol"
    readonly property real maxWidth: Math.max(160, root.width * 0.8)

    function timeText(): string {
        if (!root.timestamp)
            return "";
        const d = new Date(Number(root.timestamp));
        if (isNaN(d.getTime()))
            return "";
        const now = new Date();
        if (d.toDateString() === now.toDateString())
            return Qt.formatDateTime(d, "hh:mm");
        return Qt.formatDateTime(d, "dd/MM/yy hh:mm");
    }

    function typeIcon(): string {
        const icons = {
            "image": "image",
            "video": "videocam",
            "audio": "mic",
            "document": "description",
            "sticker": "sticky_note_2",
            "location": "location_on",
            "contact": "person",
            "unknown": "help"
        };
        return icons[root.type] || "chat";
    }

    function typeLabel(): string {
        const labels = {
            "image": "Foto",
            "video": "Vídeo",
            "audio": "Áudio",
            "document": "Documento",
            "sticker": "Figurinha",
            "location": "Localização",
            "contact": "Contato",
            "unknown": "Mensagem"
        };
        return labels[root.type] || "Mensagem";
    }

    function statusIcon(): string {
        if (root.status === "read" || root.status === "delivered")
            return "done_all";
        return "done";
    }

    implicitHeight: bubble.implicitHeight

    StyledRect {
        id: bubble

        anchors.right: root.fromMe ? parent.right : undefined
        anchors.left: root.fromMe ? undefined : parent.left
        implicitWidth: content.implicitWidth + Tokens.padding.medium * 2
        width: Math.min(root.maxWidth, implicitWidth)
        implicitHeight: content.implicitHeight + Tokens.padding.small * 2
        radius: Tokens.rounding.large
        bottomRightRadius: root.fromMe ? Tokens.rounding.extraSmall : Tokens.rounding.large
        bottomLeftRadius: root.fromMe ? Tokens.rounding.large : Tokens.rounding.extraSmall
        color: root.fromMe ? Colours.palette.m3primaryContainer : Colours.tPalette.m3surfaceContainerHigh

        ColumnLayout {
            id: content

            x: Tokens.padding.medium
            y: Tokens.padding.small
            width: bubble.width - Tokens.padding.medium * 2
            spacing: 2

            RowLayout {
                Layout.fillWidth: true
                visible: !root.isText && !root.deleted
                spacing: Tokens.spacing.extraSmall

                MaterialIcon {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.typeIcon()
                    color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                    fontStyle: Tokens.font.icon.small
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: root.typeLabel()
                    color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                    font: Tokens.font.body.small
                }
            }

            StyledText {
                Layout.fillWidth: true
                visible: root.isText || root.deleted
                text: root.deleted ? "Mensagem apagada" : root.text
                color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                font: root.deleted ? Tokens.font.body.builders.small.italic(true).build() : Tokens.font.body.small
                wrapMode: Text.Wrap
                maximumLineCount: 400
            }

            Item {
                Layout.fillWidth: true
                implicitHeight: statusRow.implicitHeight

                RowLayout {
                    id: statusRow

                    anchors.right: parent.right
                    spacing: Tokens.spacing.extraSmall

                    StyledText {
                        visible: root.edited && !root.deleted
                        text: "editada"
                        color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                    }

                    StyledText {
                        visible: root.timeText().length > 0
                        text: root.timeText()
                        color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                    }

                    MaterialIcon {
                        Layout.alignment: Qt.AlignVCenter
                        visible: root.fromMe && !root.deleted
                        text: root.statusIcon()
                        color: root.status === "read" ? Colours.palette.m3primary : (root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant)
                        fontStyle: Tokens.font.icon.builders.small.scale(0.85).build()
                    }
                }
            }
        }
    }
}
