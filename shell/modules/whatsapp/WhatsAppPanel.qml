// WhatsAppPanel — conteúdo do drawer: alterna Login (QR) <-> Lista <-> Conversa.
//
// Não tem fundo próprio (o blob do core aparece atrás). Um header enxuto traz o
// título, o indicador de conexão e as ações; o corpo é um crossfade discreto
// entre as três vistas, que permanecem vivas para preservar estado/scroll.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras.whatsapp

Item {
    id: root

    property var screen
    property var drawer

    // 0 = login, 1 = lista, 2 = conversa.
    // `paired` cobre logged_in, authState e connectionState, então o LoginView
    // nunca fica sobreposto à lista quando o daemon anuncia "connected".
    readonly property bool paired: WhatsAppClient.paired
    readonly property bool showLogin: !root.paired
    readonly property bool showChat: root.paired && String(WhatsAppClient.currentChat).length > 0
    readonly property bool showList: root.paired && !root.showChat
    // Sempre exatamente uma view ativa: nunca cai em "nenhuma visível".
    readonly property int page: root.showChat ? 2 : (root.showLogin ? 0 : 1)

    function statusColour(): color {
        if (WhatsAppClient.connectionState === "connected")
            return Colours.palette.m3success;
        if (WhatsAppClient.connectionState === "connecting")
            return Colours.palette.m3tertiary;
        return Colours.palette.m3error;
    }

    function statusLabel(): string {
        if (WhatsAppClient.connectionState === "connected")
            return "Conectado";
        if (WhatsAppClient.connectionState === "connecting")
            return "Conectando";
        if (WhatsAppClient.connectionState === "needs_pairing")
            return "Não pareado";
        return "Offline";
    }

    // Fecho após o rato sair (complementa o sensor do core).
    HoverHandler {
        id: hover

        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onHoveredChanged: {
            if (!hovered && root.drawer)
                root.drawer.scheduleHide();
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Tokens.padding.large
        anchors.bottomMargin: Tokens.padding.small
        spacing: Tokens.spacing.small

        // -------------------------------------------------------------- //
        // Header
        // -------------------------------------------------------------- //
        RowLayout {
            Layout.fillWidth: true
            // O corpo ocupa a largura inteira do drawer; só o header é
            // recuado, para não encostar no canto arredondado.
            Layout.leftMargin: Tokens.padding.large
            Layout.rightMargin: Tokens.padding.small
            spacing: Tokens.spacing.extraSmall

            IconButton {
                visible: root.showChat
                type: IconButton.Text
                icon: "arrow_back"
                onClicked: WhatsAppClient.closeChat()
            }

            ContactAvatar {
                Layout.alignment: Qt.AlignVCenter
                visible: root.showChat
                size: 28
                name: WhatsAppClient.currentChatName
                jid: WhatsAppClient.currentChat
                avatar: WhatsAppClient.currentChatAvatar
            }

            MaterialIcon {
                visible: !root.showChat
                text: "forum"
                color: Colours.palette.m3primary
                fontStyle: Tokens.font.icon.medium
            }

            StyledText {
                Layout.fillWidth: true
                text: root.showChat ? WhatsAppClient.currentChatName : "WhatsApp"
                font: Tokens.font.title.small
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            // Indicador de conexão.
            RowLayout {
                Layout.alignment: Qt.AlignVCenter
                spacing: Tokens.spacing.extraSmall

                StyledRect {
                    id: dot

                    Layout.alignment: Qt.AlignVCenter
                    Layout.preferredWidth: 8
                    Layout.preferredHeight: 8
                    radius: 4
                    color: root.statusColour()

                    Behavior on color {
                        CAnim {}
                    }
                }

                StyledText {
                    Layout.alignment: Qt.AlignVCenter
                    text: root.statusLabel()
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.small
                }
            }

            IconButton {
                type: IconButton.Text
                icon: "refresh"
                onClicked: WhatsAppClient.refreshChats()
            }

            IconButton {
                visible: root.paired && !root.showChat
                type: IconButton.Text
                icon: "logout"
                onClicked: WhatsAppClient.logout()
            }
        }

        // -------------------------------------------------------------- //
        // Corpo
        // -------------------------------------------------------------- //
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            LoginView {
                anchors.fill: parent
                opacity: root.showLogin ? 1 : 0
                visible: root.showLogin
                enabled: root.showLogin
                onGenerate: WhatsAppClient.startLogin()

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }

            ChatList {
                anchors.fill: parent
                opacity: root.showList ? 1 : 0
                visible: root.showList
                enabled: root.showList

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }

            ChatView {
                anchors.fill: parent
                opacity: root.showChat ? 1 : 0
                visible: root.showChat
                enabled: root.showChat

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }
    }
}
