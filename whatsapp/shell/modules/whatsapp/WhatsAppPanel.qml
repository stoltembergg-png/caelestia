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
    // Referência ao Drawer (injetada pelo Loader). Mantida para uso futuro; o
    // painel não a usa mais para fechar sozinho (sem auto-close por hover).
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

    // O drawer abre/fecha só por ação explícita (barra/atalho/IPC, Esc e
    // fullscreen do core). Não há fecho por hover/perda de foco.

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: Tokens.padding.large
        anchors.bottomMargin: Tokens.padding.small
        spacing: Tokens.spacing.small

        // -------------------------------------------------------------- //
        // Header contínuo: o título vive na mesma linguagem translúcida do
        // drawer, sem cartão inset/raio. O scrim tPalette só reforça contraste
        // junto ao topo e se dissolve no corpo, preservando wallpaper e matiz.
        // -------------------------------------------------------------- //
        Item {
            Layout.fillWidth: true
            implicitHeight: header.implicitHeight + Tokens.padding.small * 2

            Rectangle {
                anchors.fill: parent
                color: "transparent"
                gradient: Gradient {
                    orientation: Gradient.Vertical

                    GradientStop {
                        position: 0
                        color: Qt.alpha(Colours.tPalette.m3surfaceContainerLow, Colours.tPalette.m3surfaceContainerLow.a * 0.45)
                    }
                    GradientStop {
                        position: 0.58
                        color: Qt.alpha(Colours.tPalette.m3surfaceContainerLow, Colours.tPalette.m3surfaceContainerLow.a * 0.45)
                    }
                    GradientStop {
                        position: 1
                        color: Qt.alpha(Colours.tPalette.m3surfaceContainerLow, 0)
                    }
                }
            }

            RowLayout {
                id: header

                anchors.fill: parent
                anchors.leftMargin: Tokens.padding.large
                anchors.rightMargin: Tokens.padding.small
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

                IconButton {
                    visible: root.paired && !root.showChat
                    type: IconButton.Text
                    icon: "logout"
                    onClicked: WhatsAppClient.logout()
                }
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
