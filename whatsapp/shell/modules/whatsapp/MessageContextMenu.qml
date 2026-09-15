// MessageContextMenu — menu de contexto de um balão (responder + reações rápidas).
//
// É um overlay dentro do ChatView: um disfarce (scrim) fecha ao clicar fora e o
// cartão é posicionado perto do balão que pediu o menu. Estilo nativo
// (StyledRect + Elevation + StateLayer).

pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services

Item {
    id: root

    anchors.fill: parent
    visible: false

    property Item target: null
    property string messageId: ""
    property string chat: ""
    property bool fromMe: false
    property bool hasMedia: false

    readonly property var quickEmojis: ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    signal replyRequested(string chat, string messageId, bool fromMe)
    signal reactRequested(string chat, string messageId, string emoji)
    signal openSystemRequested(string chat, string messageId, string path)

    readonly property point _anchor: root.target ? root.target.mapToItem(root, 0, 0) : Qt.point(0, 0)
    readonly property real _ax: Math.max(8, Math.min(root.width - menu.width - 8, root._anchor.x))
    readonly property real _ay: {
        const below = root._anchor.y + (root.target ? root.target.height : 0) + 4;
        return Math.max(8, Math.min(root.height - menu.height - 8, below));
    }

    function openFor(item, id, chatJid, isFromMe, media): void {
        root.target = item;
        root.messageId = String(id || "");
        root.chat = String(chatJid || "");
        root.fromMe = isFromMe === true;
        root.hasMedia = media === true || (media && String(media.kind || "").length > 0);
        root.visible = true;
    }

    function close(): void {
        root.visible = false;
        root.target = null;
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.visible
        onClicked: root.close()
    }

    StyledRect {
        id: menu

        x: root._ax
        y: root._ay
        implicitWidth: column.implicitWidth + Tokens.padding.small * 2
        implicitHeight: column.implicitHeight + Tokens.padding.small * 2
        radius: Tokens.rounding.large
        color: Colours.palette.m3surfaceContainerHigh
        opacity: root.visible ? 1 : 0
        scale: root.visible ? 1 : 0.9

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Behavior on scale {
            Anim {
                type: Anim.FastSpatial
            }
        }

        Elevation {
            anchors.fill: parent
            radius: menu.radius
            level: 2
            z: -1
        }

        Column {
            id: column

            anchors.centerIn: parent
            spacing: Tokens.spacing.extraSmall

            // Responder
            StyledRect {
                implicitWidth: replyRow.implicitWidth
                implicitHeight: replyRow.implicitHeight + Tokens.spacing.small
                radius: Tokens.rounding.small
                color: "transparent"

                Row {
                    id: replyRow

                    anchors.centerIn: parent
                    spacing: Tokens.spacing.small

                    MaterialIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "reply"
                        color: Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.small
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Responder")
                        font: Tokens.font.body.small
                    }
                }

                StateLayer {
                    radius: parent.radius
                    onClicked: {
                        root.replyRequested(root.chat, root.messageId, root.fromMe);
                        root.close();
                    }
                }
            }

            // Abrir no sistema (ação secundária, só para mídia)
            StyledRect {
                visible: root.hasMedia
                implicitWidth: systemRow.implicitWidth
                implicitHeight: systemRow.implicitHeight + Tokens.spacing.small
                radius: Tokens.rounding.small
                color: "transparent"

                Row {
                    id: systemRow

                    anchors.centerIn: parent
                    spacing: Tokens.spacing.small

                    MaterialIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "open_in_new"
                        color: Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.small
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: qsTr("Abrir no sistema")
                        font: Tokens.font.body.small
                    }
                }

                StateLayer {
                    radius: parent.radius
                    onClicked: {
                        root.openSystemRequested(root.chat, root.messageId, "");
                        root.close();
                    }
                }
            }

            // Emojis rápidos
            Row {
                spacing: Tokens.spacing.extraSmall

                Repeater {
                    model: root.quickEmojis

                    StyledRect {
                        id: emojiCell

                        required property string modelData

                        implicitWidth: 30
                        implicitHeight: 30
                        radius: Tokens.rounding.small
                        color: "transparent"

                        StyledText {
                            anchors.centerIn: parent
                            text: emojiCell.modelData
                            font: Tokens.font.body.medium
                        }

                        StateLayer {
                            radius: parent.radius
                            onClicked: {
                                root.reactRequested(root.chat, root.messageId, emojiCell.modelData);
                                root.close();
                            }
                        }
                    }
                }
            }
        }
    }
}
