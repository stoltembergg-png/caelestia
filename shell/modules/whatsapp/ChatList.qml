// ChatList — lista de conversas (nome, avatar, prévia, hora e não lidas).
//
// O modelo é o ListModel exposto por WhatsAppClient.chats. O clique abre a
// conversa; o badge de não lidas soma no contador global do serviço.

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

    VerticalFadeListView {
        id: list

        anchors.fill: parent
        model: WhatsAppClient.chats
        spacing: 2
        boundsBehavior: Flickable.StopAtBounds

        delegate: Component {
            Item {
                id: row

                required property string jid
                required property string kind
                required property string name
                required property string lastMessage
                required property string timestamp
                required property int unread

                width: ListView.view ? ListView.view.width : 0
                height: Tokens.padding.extraLarge * 3

                readonly property bool selected: WhatsAppClient.currentChat === row.jid
                readonly property real badgeWidth: row.unread > 0 ? Math.max(20, badgeLabel.implicitWidth + Tokens.spacing.small) : 0

                function timeText(ts): string {
                    if (!ts)
                        return "";
                    const d = new Date(Number(ts));
                    if (isNaN(d.getTime()))
                        return "";
                    const now = new Date();
                    if (d.toDateString() === now.toDateString())
                        return Qt.formatDateTime(d, "hh:mm");
                    return Qt.formatDateTime(d, "dd/MM/yy");
                }

                StyledRect {
                    anchors.fill: parent
                    anchors.margins: Tokens.spacing.extraSmall / 2
                    radius: Tokens.rounding.large
                    color: row.selected ? Colours.tPalette.m3secondaryContainer : "transparent"

                    Behavior on color {
                        CAnim {}
                    }
                }

                ContactAvatar {
                    id: avatar

                    anchors.left: parent.left
                    anchors.leftMargin: Tokens.padding.small
                    anchors.verticalCenter: parent.verticalCenter
                    size: 44
                    name: row.name
                    jid: row.jid
                }

                // Coluna meta (hora + badge): Item com âncoras para alinhar à
                // direita sem depender de positioner.
                Item {
                    id: meta

                    anchors.right: parent.right
                    anchors.rightMargin: Tokens.padding.medium
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(timeLabel.implicitWidth, row.badgeWidth)
                    height: timeLabel.implicitHeight + (row.unread > 0 ? 6 + 20 : 0)

                    StyledText {
                        id: timeLabel

                        anchors.right: parent.right
                        text: row.timeText(row.timestamp)
                        color: row.unread > 0 ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.label.small
                    }

                    StyledRect {
                        anchors.right: parent.right
                        anchors.top: timeLabel.bottom
                        anchors.topMargin: 6
                        width: row.badgeWidth
                        height: 20
                        radius: 10
                        visible: row.unread > 0
                        color: Colours.palette.m3primary

                        StyledText {
                            id: badgeLabel

                            anchors.centerIn: parent
                            text: row.unread > 99 ? "99+" : String(row.unread)
                            color: Colours.palette.m3onPrimary
                            font: Tokens.font.label.small
                        }
                    }
                }

                Column {
                    anchors.left: avatar.right
                    anchors.leftMargin: Tokens.padding.medium
                    anchors.right: meta.left
                    anchors.rightMargin: Tokens.spacing.small
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        width: parent.width
                        text: row.name
                        font: row.unread > 0 ? Tokens.font.body.builders.medium.weight(Font.DemiBold).build() : Tokens.font.body.medium
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    StyledText {
                        width: parent.width
                        text: row.lastMessage.length > 0 ? row.lastMessage : "—"
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.small
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }

                StateLayer {
                    anchors.fill: parent
                    anchors.margins: Tokens.spacing.extraSmall / 2
                    radius: Tokens.rounding.large
                    onClicked: WhatsAppClient.openChat(row.jid)
                }
            }
        }
    }

    // Estado vazio.
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width * 0.8, 280)
        spacing: Tokens.spacing.small
        visible: WhatsAppClient.chats.count === 0

        MaterialIcon {
            Layout.alignment: Qt.AlignHCenter
            text: "forum"
            color: Colours.palette.m3onSurfaceVariant
            fontStyle: Tokens.font.icon.extraLarge
        }

        StyledText {
            Layout.fillWidth: true
            text: WhatsAppClient.loggedIn ? "Nenhuma conversa ainda" : "Conecte um dispositivo para começar"
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.medium
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
    }
}
