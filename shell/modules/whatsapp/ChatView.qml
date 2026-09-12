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
import qs.extras.whatsapp

Item {
    id: root

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
                spacing: Tokens.spacing.extraSmall
                topMargin: Tokens.spacing.small
                bottomMargin: Tokens.spacing.small
                boundsBehavior: Flickable.StopAtBounds
                reuseItems: false

                delegate: Component {
                    Item {
                        id: wrapper

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

                        width: ListView.view ? ListView.view.width : 0
                        height: bubble.implicitHeight

                        MessageBubble {
                            id: bubble

                            anchors.left: parent.left
                            anchors.right: parent.right
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

                            onContextRequested: contextMenu.openFor(bubble, wrapper.messageId, wrapper.chat, wrapper.fromMe)
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
                    text: "Sem mensagens"
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
    }

    Connections {
        target: WhatsAppClient

        function onMessageAppended(jid) {
            if (jid === WhatsAppClient.currentChat)
                Qt.callLater(() => list.positionViewAtEnd());
        }

        function onCurrentChatChanged() {
            Qt.callLater(() => list.positionViewAtEnd());
        }
    }
}
