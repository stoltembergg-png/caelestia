// MessageBubble — balão de mensagem (entrada à esquerda, saída à direita).
//
// Suporta texto, mídia (delegada ao MediaContent), citação (quote) e chips de
// reação. Clique direito/long-press pede o menu de contexto (responder/emoji)
// via o sinal `contextRequested`. Cores/raios dos tokens do shell.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.extras.whatsapp

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
    property string quotedText: ""
    property bool quotedFromMe: false
    property bool edited: false
    property bool deleted: false
    property string status: ""
    property var media: null
    property string localPath: ""
    property var upload: null
    property string reactions: ""

    signal contextRequested()

    readonly property var _reactions: WhatsAppClient.reactionsOf(root.reactions)

    readonly property bool isText: root.type === "text" || root.type === "protocol"
    readonly property bool isMedia: root.type === "image" || root.type === "video" || root.type === "audio" || root.type === "document" || root.type === "sticker"
    readonly property bool isOtherType: !root.isText && !root.isMedia
    readonly property bool showCaption: (root.type === "image" || root.type === "video" || root.type === "sticker") && root.text.length > 0
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
            "location": "location_on",
            "contact": "person",
            "unknown": "help"
        };
        return icons[root.type] || "chat";
    }

    function typeLabel(): string {
        const labels = {
            "location": "Localização",
            "contact": "Contato",
            "unknown": "Mensagem"
        };
        return labels[root.type] || "Mensagem";
    }

    function statusIcon(): string {
        if (root.upload && root.upload.state === "sending")
            return "schedule";
        if (root.upload && root.upload.state === "failed")
            return "error_outline";
        if (root.status === "read" || root.status === "delivered")
            return "done_all";
        return "done";
    }

    // Reações agrupadas por emoji (contagem + se é minha).
    function groupedReactions(): var {
        const map = ({});
        const order = [];
        const list = root._reactions;
        for (let i = 0; i < list.length; i++) {
            const e = String(list[i].emoji || "");
            if (!e.length)
                continue;
            if (!map[e]) {
                map[e] = {
                    "emoji": e,
                    "count": 0,
                    "mine": false
                };
                order.push(e);
            }
            map[e].count++;
            if (list[i].fromMe === true)
                map[e].mine = true;
        }
        return order.map(function (e) {
            return map[e];
        });
    }

    implicitHeight: bubble.implicitHeight

    // Contexto (clique direito / long-press). Fica atrás do conteúdo para não
    // roubar o clique da mídia.
    MouseArea {
        anchors.fill: parent
        enabled: !root.upload
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressAndHold: root.contextRequested()
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                root.contextRequested();
        }
    }

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
            spacing: Tokens.spacing.extraSmall

            // Citação
            StyledClippingRect {
                Layout.fillWidth: true
                visible: root.quotedId.length > 0
                implicitHeight: quoteCol.implicitHeight + Tokens.spacing.small
                radius: Tokens.rounding.small
                color: root.fromMe ? Qt.alpha(Colours.palette.m3onPrimaryContainer, 0.14) : Colours.tPalette.m3surfaceContainerHighest

                StyledRect {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: 2
                    color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3primary
                }

                Column {
                    id: quoteCol

                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.spacing.small
                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.spacing.extraSmall
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0

                    StyledText {
                        width: parent.width
                        text: root.quotedFromMe ? "Você" : WhatsAppClient._chatName(root.chat)
                        color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3primary
                        font: Tokens.font.label.small
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    StyledText {
                        width: parent.width
                        text: root.quotedText.length > 0 ? root.quotedText : "Mensagem citada"
                        color: root.fromMe ? Qt.alpha(Colours.palette.m3onPrimaryContainer, 0.85) : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }
            }

            // Mídia
            MediaContent {
                Layout.fillWidth: false
                visible: root.isMedia
                chat: root.chat
                messageId: root.messageId
                type: root.type
                text: root.text
                media: root.media
                localPath: root.localPath
                upload: root.upload
                fromMe: root.fromMe
            }

            // Tipos simples (localização/contato)
            RowLayout {
                Layout.fillWidth: true
                visible: root.isOtherType && !root.deleted
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
                    text: root.text.length > 0 ? root.text : root.typeLabel()
                    color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                    font: Tokens.font.body.small
                    elide: Text.ElideRight
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

            StyledText {
                Layout.fillWidth: true
                visible: root.showCaption
                text: root.text
                color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                font: Tokens.font.body.small
                wrapMode: Text.Wrap
                maximumLineCount: 6
                elide: Text.ElideRight
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
                        color: (root.upload && root.upload.state === "failed") ? Colours.palette.m3error : (root.status === "read" ? Colours.palette.m3primary : (root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant))
                        fontStyle: Tokens.font.icon.builders.small.scale(0.85).build()
                    }
                }
            }

            // Chips de reação
            Flow {
                Layout.fillWidth: true
                visible: root.groupedReactions().length > 0
                spacing: Tokens.spacing.extraSmall

                Repeater {
                    model: root.groupedReactions()

                    StyledRect {
                        id: chip

                        required property var modelData

                        implicitWidth: chipRow.implicitWidth + Tokens.spacing.small
                        implicitHeight: 22
                        radius: 11
                        color: chip.modelData.mine ? Qt.alpha(Colours.palette.m3primary, 0.28) : Colours.tPalette.m3surfaceContainerHighest

                        Row {
                            id: chipRow

                            anchors.centerIn: parent
                            spacing: 2

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: chip.modelData.emoji
                                font: Tokens.font.body.small
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: chip.modelData.count > 1
                                text: String(chip.modelData.count)
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.small
                            }
                        }

                        StateLayer {
                            radius: parent.radius
                            onClicked: WhatsAppClient.toggleReaction(root.chat, root.messageId, chip.modelData.emoji)
                        }
                    }
                }
            }
        }
    }
}
