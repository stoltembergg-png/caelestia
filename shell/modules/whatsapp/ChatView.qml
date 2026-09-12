// ChatView — histórico da conversa aberta + composer.
//
// O modelo (WhatsAppClient.messages) já chega em ordem cronológica (antigo ->
// recente). Rolamos para o fim a cada mensagem nova; o read é disparado pelo
// serviço ao abrir e ao receber.

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
                boundsBehavior: Flickable.StopAtBounds

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
                        required property bool edited
                        required property bool deleted
                        required property string status

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
                            edited: wrapper.edited
                            deleted: wrapper.deleted
                            status: wrapper.status
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
            Layout.fillWidth: true
        }
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
