// ChatView — histórico da conversa aberta + composer.
//
// O modelo (WhatsAppClient.messages) já chega em ordem cronológica (antigo ->
// recente). Rolamos para o fim a cada mensagem nova; o read é disparado pelo
// serviço ao abrir e ao receber. Aceita arquivo solto (DropArea) sobre a
// conversa e um menu de contexto para responder/reagir.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services
import qs.extras
import qs.extras.whatsapp

Item {
    id: root

    // Scrim sutil no rodapé: reduz o bleed do fundo translúcido atrás do
    // composer e do último balão (mantém a transparência geral do painel).
    StyledRect {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.min(parent.height * 0.26, 190)
        gradient: Gradient {
            GradientStop {
                position: 0
                color: "transparent"
            }
            GradientStop {
                position: 1
                color: Qt.alpha(Colours.palette.m3surface, 0.92)
            }
        }
    }

    readonly property bool compact: WhatsAppSettings.getBool("compactMode", false)

    // A mídia carrega de forma assíncrona e aumenta o contentHeight DEPOIS do
    // positionViewAtEnd. Re-posiciona por uma janela curta (~1,8 s) após abrir/
    // receber, garantindo que o último balão (legenda/timestamp/cauda) pare no
    // fim real. Não cancelamos em movementStarted: o próprio
    // positionViewAtEnd() emite movimento e mataria a janela antes da altura
    // assentar (era o que escondia o timestamp/cauda do último balão).
    function stickBottom(): void {
        stickTimer.restart();
    }

    Timer {
        id: stickTimer

        interval: 150
        repeat: true
        property int ticks: 0

        onTriggered: {
            ticks++;
            list.positionViewAtEnd();
            if (ticks >= 12)
                stop();
        }
        onRunningChanged: {
            if (running)
                ticks = 0;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Tokens.spacing.small

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            VerticalFadeListView {
                id: list

                anchors.fill: parent
                model: WhatsAppClient.messages
                // O ritmo vertical é do delegate (dia/grupo), não do ListView.
                spacing: 0
                // Fade só no topo: sem fade inferior, a legenda/timestamp/cauda
                // do último balão não somem no gradiente (o rodapé fica por
                // conta do scrim sutil atrás do composer).
                fadeAmount: root.compact ? 0.035 : 0.04
                bottomFadeOpacity: 1
                topMargin: Math.round(height * fadeAmount) + Tokens.spacing.small
                bottomMargin: root.compact ? Tokens.padding.medium : Tokens.padding.large
                boundsBehavior: Flickable.StopAtBounds
                reuseItems: true
                cacheBuffer: 4000

                delegate: Component {
                    Item {
                        id: wrapper

                        required property int index
                        required property string messageId
                        required property string chat
                        required property string sender
                        required property bool fromMe
                        required property string timestamp
                        required property string type
                        required property string text
                        required property string quotedId
                        required property string quotedText
                        required property bool quotedFromMe
                        required property bool edited
                        required property bool deleted
                        required property string status
                        required property var media
                        required property string reactions
                        required property string localPath
                        required property var upload

                        readonly property var _prev: wrapper.index > 0 ? WhatsAppClient.messages.get(wrapper.index - 1) : null
                        readonly property var _next: wrapper.index < WhatsAppClient.messages.count - 1 ? WhatsAppClient.messages.get(wrapper.index + 1) : null

                        function _dayKey(ts): string {
                            const d = new Date(Number(ts || 0));
                            if (isNaN(d.getTime()))
                                return "";
                            return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2);
                        }

                        function _dayLabel(ts): string {
                            const d = new Date(Number(ts || 0));
                            if (isNaN(d.getTime()))
                                return "";
                            const now = new Date();
                            const a = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
                            const t = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
                            if (a === t)
                                return I18n.t("whatsapp.chat_view.today");
                            if (a === t - 86400000)
                                return I18n.t("whatsapp.chat_view.yesterday");
                            return Qt.formatDateTime(d, "dd/MM/yyyy");
                        }

                        readonly property bool dayStart: !wrapper._prev || wrapper._dayKey(wrapper._prev.timestamp) !== wrapper._dayKey(wrapper.timestamp)
                        readonly property bool groupStart: wrapper.dayStart || !wrapper._prev || wrapper._prev.fromMe !== wrapper.fromMe || wrapper._prev.sender !== wrapper.sender
                        readonly property bool groupEnd: !wrapper._next || wrapper._next.fromMe !== wrapper.fromMe || wrapper._next.sender !== wrapper.sender || wrapper._dayKey(wrapper._next.timestamp) !== wrapper._dayKey(wrapper.timestamp)
                        readonly property real gapGroup: root.compact ? Tokens.spacing.small : Tokens.spacing.medium
                        readonly property real gapTight: root.compact ? 1 : 2
                        readonly property real topGap: wrapper.dayStart ? (dayPill.implicitHeight + wrapper.gapGroup) : (wrapper.groupStart ? wrapper.gapGroup : wrapper.gapTight)

                        width: ListView.view ? ListView.view.width : 0
                        height: wrapper.topGap + bubble.implicitHeight

                        // Separador de dia (Hoje/Ontem/data)
                        StyledRect {
                            id: dayPill

                            visible: wrapper.dayStart
                            anchors.top: parent.top
                            anchors.horizontalCenter: parent.horizontalCenter
                            implicitWidth: dayLabel.implicitWidth + Tokens.spacing.medium * 2
                            implicitHeight: dayLabel.implicitHeight + Tokens.spacing.extraSmall
                            radius: Tokens.rounding.full
                            color: Colours.tPalette.m3surfaceContainerHighest

                            StyledText {
                                id: dayLabel

                                anchors.centerIn: parent
                                text: wrapper._dayLabel(wrapper.timestamp)
                                color: Colours.palette.m3onSurfaceVariant
                                font: Tokens.font.label.small
                            }
                        }

                        MessageBubble {
                            id: bubble

                            anchors.left: parent.left
                            anchors.right: parent.right
                            // Espaço lateral para a cauda protruir sem ser clipada.
                            anchors.leftMargin: root.compact ? 7 : 10
                            anchors.rightMargin: root.compact ? 7 : 10
                            y: wrapper.topGap
                            messageId: wrapper.messageId
                            chat: wrapper.chat
                            sender: wrapper.sender
                            fromMe: wrapper.fromMe
                            timestamp: wrapper.timestamp
                            type: wrapper.type
                            text: wrapper.text
                            quotedId: wrapper.quotedId
                            quotedText: wrapper.quotedText
                            quotedFromMe: wrapper.quotedFromMe
                            edited: wrapper.edited
                            deleted: wrapper.deleted
                            status: wrapper.status
                            media: wrapper.media
                            reactions: wrapper.reactions
                            localPath: wrapper.localPath
                            upload: wrapper.upload
                            compact: root.compact
                            groupStart: wrapper.groupStart
                            groupEnd: wrapper.groupEnd

                            onContextRequested: contextMenu.openFor(bubble, wrapper.messageId, wrapper.chat, wrapper.fromMe, !!(wrapper.media && String(wrapper.media.kind || "").length))
                        }
                    }
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                width: Math.min(parent.width * 0.8, 240)
                spacing: Tokens.spacing.small
                visible: WhatsAppClient.messages.count === 0

                MaterialIcon {
                    Layout.alignment: Qt.AlignHCenter
                    text: "chat_bubble"
                    color: Colours.palette.m3onSurfaceVariant
                    fontStyle: Tokens.font.icon.extraLarge
                }

                StyledText {
                    Layout.fillWidth: true
                    text: I18n.t("whatsapp.chat_view.empty")
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.medium
                    horizontalAlignment: Text.AlignHCenter
                }
            }
        }

        MessageComposer {
            id: composer

            Layout.fillWidth: true
        }
    }

    // Destaque de arrastar-e-soltar
    StyledRect {
        anchors.fill: parent
        visible: dropArea.containsDrag
        radius: Tokens.rounding.large
        color: Qt.alpha(Colours.palette.m3primary, 0.06)
        border.width: 1
        border.color: Colours.palette.m3primary
        z: 50
    }

    DropArea {
        id: dropArea

        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: drop => {
            if (drop.hasUrls && drop.urls.length > 0)
                composer.stageUrl(drop.urls[0]);
        }
    }

    MessageContextMenu {
        id: contextMenu

        onReplyRequested: (chat, messageId, fromMe) => WhatsAppClient.beginReply(chat, messageId, fromMe)
        onReactRequested: (chat, messageId, emoji) => WhatsAppClient.react(chat, messageId, emoji)
        onOpenSystemRequested: (chat, messageId, path) => WhatsAppClient.openMedia(chat, messageId, path)
    }

    Connections {
        target: WhatsAppClient

        function onMessageAppended(jid) {
            if (jid === WhatsAppClient.currentChat)
                root.stickBottom();
        }

        function onCurrentChatChanged() {
            root.stickBottom();
        }
    }
}
