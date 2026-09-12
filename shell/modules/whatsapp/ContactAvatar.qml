// ContactAvatar — avatar circular com fallback de iniciais coloridas.
//
// Nesta fase não há mídia de avatar no IPC: `avatarPath` existe para o futuro e,
// quando vazio (sempre, por ora), desenhamos as iniciais sobre uma cor estável
// derivada do JID. Grupos (`@g.us`) usam o ícone de grupo.

pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    property string name: ""
    property string jid: ""
    property string avatarPath: ""
    property real size: 44

    readonly property bool isGroup: root.jid.indexOf("@g.us") >= 0
    property bool _imageOk: false

    readonly property var _palette: [
        Colours.palette.m3primaryContainer,
        Colours.palette.m3secondaryContainer,
        Colours.palette.m3tertiaryContainer
    ]

    readonly property int _hash: {
        let h = 0;
        const s = String(root.jid || root.name || "?");
        for (let i = 0; i < s.length; i++)
            h = (h * 31 + s.charCodeAt(i)) % 100000;
        return h;
    }

    readonly property color _background: root._palette[root._hash % root._palette.length]

    function initials(): string {
        const s = String(root.name || "").trim();
        if (!s.length)
            return "?";
        const clean = s.replace(/^\+/, "");
        const parts = clean.split(/\s+/).filter(function (p) {
            return p.length > 0;
        });
        if (parts.length >= 2)
            return String(parts[0].charAt(0) + parts[1].charAt(0)).toUpperCase();
        const alnum = clean.replace(/[^0-9A-Za-zÀ-ÿ]/g, "");
        const base = alnum.length ? alnum : clean;
        return String(base).substring(0, 2).toUpperCase();
    }

    implicitWidth: root.size
    implicitHeight: root.size

    StyledRect {
        anchors.fill: parent
        radius: width / 2
        color: root._background
    }

    Image {
        anchors.fill: parent
        visible: root._imageOk
        source: root.avatarPath ? "file://" + root.avatarPath : ""
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize: Qt.size(root.size, root.size)
        onStatusChanged: root._imageOk = (status === Image.Ready)
    }

    MaterialIcon {
        anchors.centerIn: parent
        visible: !root._imageOk && root.isGroup
        text: "group"
        color: Colours.on(root._background)
        fontStyle: Tokens.font.icon.medium
    }

    StyledText {
        anchors.centerIn: parent
        visible: !root._imageOk && !root.isGroup
        text: root.initials()
        color: Colours.on(root._background)
        font: Tokens.font.title.small
    }
}
