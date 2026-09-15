// WhatsAppBarItem — item compacto para a barra vertical.
//
// Mostra o ícone do WhatsApp, um badge com o total de não lidas
// (WhatsAppClient.unreadCount) e um ponto de offline quando não há sessão
// pareada/conectada. Clique alterna o drawer (WhatsAppState.toggle).
//
// Visual nativo: StyledRect + radius full + Colours.tPalette.m3surfaceContainer
// + StateLayer, na mesma linguagem do NoLimitsBarItem. Sem mídia/avatars aqui.

pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services
import qs.extras.whatsapp

Item {
    id: root

    // Injetado pela barra (DelegateChoice, patch do core). Mantido para uso
    // futuro (popout/hover) e para casar com o `bar: root` emitido pelo patch.
    property var bar

    readonly property bool paired: WhatsAppClient.paired
    readonly property int unread: WhatsAppClient.unreadCount
    readonly property bool offline: !root.paired
    readonly property real dotSize: Math.max(6, Math.round(Tokens.sizes.bar.innerWidth * 0.18))

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: Tokens.sizes.bar.innerWidth

    StyledRect {
        anchors.fill: parent
        radius: Tokens.rounding.full
        color: Colours.tPalette.m3surfaceContainer

        StateLayer {
            anchors.fill: parent
            radius: Tokens.rounding.full
            onClicked: WhatsAppState.toggle()
        }

        MaterialIcon {
            id: icon

            anchors.centerIn: parent
            text: "forum"
            color: root.offline ? Colours.palette.m3onSurfaceVariant : Colours.palette.m3primary
            fontStyle: Tokens.font.icon.medium
            opacity: root.offline ? 0.55 : 1

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Behavior on color {
                CAnim {}
            }
        }

        // Badge de não lidas (canto superior direito).
        StyledRect {
            visible: root.unread > 0
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: Tokens.padding.extraSmall / 2
            anchors.rightMargin: Tokens.padding.extraSmall / 2
            implicitWidth: Math.max(badgeText.implicitHeight + Tokens.padding.extraSmall, badgeText.implicitWidth + Tokens.padding.extraSmall / 2)
            implicitHeight: badgeText.implicitHeight + Tokens.padding.extraSmall / 2
            radius: height / 2
            color: Colours.palette.m3primary

            StyledText {
                id: badgeText

                anchors.centerIn: parent
                text: root.unread > 99 ? "99+" : String(root.unread)
                color: Colours.palette.m3onPrimary
                font: Tokens.font.label.builders.small.scale(0.72).build()
            }
        }

        // Ponto de offline (canto inferior direito).
        StyledRect {
            visible: root.offline
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.bottomMargin: Tokens.padding.extraSmall / 2
            anchors.rightMargin: Tokens.padding.extraSmall / 2
            implicitWidth: root.dotSize
            implicitHeight: root.dotSize
            radius: width / 2
            color: Colours.palette.m3error
        }
    }
}
