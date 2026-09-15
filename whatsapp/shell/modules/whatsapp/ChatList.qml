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

    readonly property bool compact: WhatsAppSettings.getBool("compactMode", false)

    VerticalFadeListView {
        id: list

        anchors.fill: parent
        model: WhatsAppClient.chats
        spacing: 2
        topMargin: Tokens.spacing.small
        bottomMargin: Tokens.padding.extraLarge
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        cacheBuffer: 2000

        delegate: Component {
            Item {
                id: row

                required property string jid
                required property string kind
                required property string name
                required property string lastMessage
                required property string timestamp
                required property int unread
                required property string avatar

                width: ListView.view ? ListView.view.width : 0
                height: root.compact ? 60 : Tokens.padding.extraLarge * 3

                readonly property bool selected: WhatsAppClient.currentChat === row.jid
                readonly property real badgeWidth: row.unread > 0 ? Math.max(20, badgeLabel.implicitWidth + Tokens.spacing.small) : 0

                // Dia da semana em PT (consistente com "ontem"/"agora"/"min";
                // evita misturar "ontem" com "Wed"/"Tue" do locale do sistema).
                function weekdayPT(d): string {
                    const days = ["dom", "seg", "ter", "qua", "qui", "sex", "sáb"];
                    return days[d.getDay()] || Qt.formatDateTime(d, "ddd");
                }

                // Hora relativa curta: "agora", "N min", "hh:mm", "ontem",
                // dia da semana ou data. Timestamp é string de ms (só formata).
                function timeText(ts): string {
                    if (!ts)
                        return "";
                    const d = new Date(Number(ts));
                    if (isNaN(d.getTime()))
                        return "";
                    const now = new Date();
                    const diff = now.getTime() - d.getTime();
                    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
                    if (d.getTime() >= startOfToday) {
                        const mins = Math.floor(diff / 60000);
                        if (mins < 1)
                            return "agora";
                        if (mins < 60)
                            return mins + " min";
                        return Qt.formatDateTime(d, "hh:mm");
                    }
                    if (d.getTime() >= startOfToday - 86400000)
                        return "ontem";
                    if (d.getTime() >= startOfToday - 6 * 86400000)
                        return row.weekdayPT(d);
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
                    anchors.leftMargin: root.compact ? Tokens.padding.small : Tokens.padding.medium
                    anchors.verticalCenter: parent.verticalCenter
                    size: root.compact ? 34 : 44
                    name: row.name
                    jid: row.jid
                    avatar: row.avatar
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
                    anchors.leftMargin: root.compact ? Tokens.spacing.small : Tokens.padding.medium
                    anchors.right: meta.left
                    anchors.rightMargin: Tokens.spacing.small
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: root.compact ? 0 : 2

                    StyledText {
                        width: parent.width
                        text: row.name
                        font: row.unread > 0 ? Tokens.font.body.builders.medium.weight(Font.DemiBold).build() : (root.compact ? Tokens.font.body.small : Tokens.font.body.medium)
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }

                    StyledText {
                        width: parent.width
                        text: row.lastMessage.length > 0 ? row.lastMessage : "—"
                        color: Colours.palette.m3onSurfaceVariant
                        font: root.compact ? Tokens.font.label.small : Tokens.font.body.small
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
