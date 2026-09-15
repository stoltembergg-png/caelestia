// MessageBubble — balão de mensagem (entrada à esquerda, saída à direita).
//
// Suporta texto, mídia (delegada ao MediaContent), citação (quote) e chips de
// reação. Clique direito/long-press pede o menu de contexto (responder/emoji)
// via o sinal `contextRequested`. Cores/raios dos tokens do shell.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Caelestia.Config
import qs.components
import qs.services
import qs.extras
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
    property bool compact: false
    // Ritmo/agrupamento (calculado pelo delegate a partir dos vizinhos).
    property bool groupStart: true
    property bool groupEnd: true

    signal contextRequested()

    readonly property var _reactions: WhatsAppClient.reactionsOf(root.reactions)
    readonly property real _hpad: root.compact ? Tokens.padding.small : Tokens.padding.medium
    readonly property real _vpad: root.compact ? Tokens.spacing.extraSmall : Tokens.padding.small
    readonly property real _spacing: root.compact ? 2 : Tokens.spacing.extraSmall

    readonly property bool isText: root.type === "text" || root.type === "protocol"
    readonly property bool isMedia: root.type === "image" || root.type === "video" || root.type === "audio" || root.type === "document" || root.type === "sticker"
    readonly property bool isOtherType: !root.isText && !root.isMedia
    readonly property bool showCaption: (root.type === "image" || root.type === "video" || root.type === "sticker") && root.text.length > 0
    readonly property real maxWidth: Math.max(160, root.width * (root.compact ? 0.86 : 0.8))
    readonly property font _bodyFont: root.deleted ? Tokens.font.body.builders.small.italic(true).build() : Tokens.font.body.small
    readonly property real _maxContentW: Math.max(80, root.maxWidth - root._hpad * 2)

    // Medição "sem wrap" (TextMetrics) para dimensionar o balão de forma
    // estável: sem depender do implicitWidth do Text já quebrado, que podia
    // ficar preso em delegate reutilizado (reuseItems).
    TextMetrics {
        id: bodyMetrics

        text: root.deleted ? I18n.t("whatsapp.message.deleted") : root.text
        font: root._bodyFont
    }

    TextMetrics {
        id: captionMetrics

        text: root.text
        font: Tokens.font.body.small
    }

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
            "location": I18n.t("whatsapp.media.location"),
            "contact": I18n.t("whatsapp.media.contact"),
            "unknown": I18n.t("whatsapp.message.message")
        };
        return labels[root.type] || I18n.t("whatsapp.message.message");
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
        implicitWidth: Math.max(content.implicitWidth, statusRow.implicitWidth) + root._hpad * 2
        width: Math.min(root.maxWidth, implicitWidth)
        implicitHeight: content.implicitHeight + root._vpad * 2
        radius: Tokens.rounding.large
        // Superfícies M3: saída = primaryContainer (azul); entrada =
        // surfaceContainerHighest com um fio sutil para descolar do painel.
        color: root.fromMe ? Colours.palette.m3primaryContainer : Colours.tPalette.m3surfaceContainerHighest
        border.width: root.fromMe ? 0 : 1
        border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.45)
        // "Cauda" só no fim do grupo; dentro do grupo o canto do remetente fica
        // um pouco menor para sugerir a pilha (ritmo).
        topLeftRadius: (!root.fromMe && !root.groupStart) ? Tokens.rounding.small : Tokens.rounding.large
        topRightRadius: (root.fromMe && !root.groupStart) ? Tokens.rounding.small : Tokens.rounding.large
        bottomLeftRadius: !root.fromMe ? (root.groupEnd ? 0 : Tokens.rounding.small) : Tokens.rounding.large
        bottomRightRadius: root.fromMe ? (root.groupEnd ? 0 : Tokens.rounding.small) : Tokens.rounding.large

        ColumnLayout {
            id: content

            x: root._hpad
            y: root._vpad
            width: bubble.width - root._hpad * 2
            spacing: root._spacing

            // Citação
            StyledClippingRect {
                id: quoteBlock

                Layout.fillWidth: true
                visible: root.quotedId.length > 0
                implicitWidth: quoteCol.implicitWidth + Tokens.spacing.small + Tokens.spacing.extraSmall
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
                        text: root.quotedFromMe ? I18n.t("whatsapp.message.you") : WhatsAppClient._chatName(root.chat)
                        color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3primary
                        font: Tokens.font.label.small
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    StyledText {
                        width: parent.width
                        text: root.quotedText.length > 0 ? root.quotedText : I18n.t("whatsapp.message.quoted")
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
                compact: root.compact
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
                Layout.fillWidth: false
                Layout.preferredWidth: Math.min(bodyMetrics.advanceWidth, root._maxContentW)
                visible: root.isText || root.deleted
                text: root.deleted ? I18n.t("whatsapp.message.deleted") : root.text
                color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                font: root._bodyFont
                wrapMode: Text.Wrap
                maximumLineCount: 400
            }

            StyledText {
                Layout.fillWidth: false
                Layout.preferredWidth: Math.min(captionMetrics.advanceWidth, root._maxContentW)
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
                implicitWidth: statusRow.implicitWidth
                implicitHeight: statusRow.implicitHeight

                RowLayout {
                    id: statusRow

                    anchors.right: parent.right
                    spacing: Tokens.spacing.extraSmall

                    StyledText {
                        visible: root.edited && !root.deleted
                        text: I18n.t("whatsapp.message.edited")
                        color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignVCenter
                        visible: root.timeText().length > 0
                        text: root.timeText()
                        color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                        wrapMode: Text.NoWrap
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

            // Chips de reação (lado a lado; menores no compacto)
            Row {
                Layout.fillWidth: false
                visible: root.groupedReactions().length > 0
                spacing: Tokens.spacing.extraSmall

                Repeater {
                    model: root.groupedReactions()

                    StyledRect {
                        id: chip

                        required property var modelData

                        implicitWidth: chipRow.implicitWidth + (root.compact ? Tokens.spacing.extraSmall : Tokens.spacing.small)
                        implicitHeight: root.compact ? 18 : 22
                        radius: height / 2
                        color: chip.modelData.mine ? Qt.alpha(Colours.palette.m3primary, 0.28) : Colours.tPalette.m3surfaceContainerHighest

                        Row {
                            id: chipRow

                            anchors.centerIn: parent
                            spacing: 2

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: chip.modelData.emoji
                                font: root.compact ? Tokens.font.label.small : Tokens.font.body.small
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

        // Cauda (só no fim do grupo): triângulo que "sai" do canto do
        // remetente e funde com o canto reto do balão.
        Shape {
            id: tail

            visible: root.groupEnd
            width: 8
            height: 10
            x: root.fromMe ? bubble.width : -width
            y: bubble.height - height

            ShapePath {
                fillColor: bubble.color
                strokeWidth: 0
                startX: root.fromMe ? 0 : tail.width
                startY: 0
                PathLine {
                    x: root.fromMe ? tail.width : 0
                    y: tail.height
                }
                PathLine {
                    x: root.fromMe ? 0 : tail.width
                    y: tail.height
                }
                PathLine {
                    x: root.fromMe ? 0 : tail.width
                    y: 0
                }
            }
        }
    }
}
