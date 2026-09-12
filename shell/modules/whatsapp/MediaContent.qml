// MediaContent — corpo de mídia de um balão (recebido ou em envio).
//
// Só usa caminhos (nunca bytes): thumb/full vêm de `media.thumb`/`media.path`;
// no envio otimista usa `localPath` como preview. O clique baixa (media.download)
// quando necessário e abre o arquivo com xdg-open. Estados de envio (upload):
// enviando (spinner + pct) e falha (tentar de novo / descartar).

pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras.whatsapp

Item {
    id: root

    property string chat: ""
    property string messageId: ""
    property string type: "text"
    property string text: ""
    property var media: null
    property string localPath: ""
    property var upload: null
    property bool fromMe: false

    property bool _busy: false
    property bool _error: false

    readonly property bool _pending: root.upload !== null && root.upload !== undefined
    readonly property bool _sending: root._pending && String(root.upload.state) === "sending"
    readonly property bool _failed: root._pending && String(root.upload.state) === "failed"
    readonly property int _pct: root._pending ? Number(root.upload.pct || 0) : 0

    readonly property string _kind: {
        const k = root.media && root.media.kind ? String(root.media.kind) : "";
        return k.length ? k : root.type;
    }
    readonly property bool _imageLike: root._kind === "image" || root._kind === "sticker"
    readonly property bool _framed: root._imageLike || root._kind === "video"
    readonly property string _path: root.media ? String(root.media.path || "") : ""
    readonly property string _thumb: root.media ? String(root.media.thumb || "") : ""
    readonly property string _local: root._pending ? String(root.localPath || "") : ""
    readonly property bool _hasImage: root._path.length > 0 || root._thumb.length > 0 || root._local.length > 0
    readonly property string _imageSource: {
        const p = root._path.length ? root._path : (root._thumb.length ? root._thumb : root._local);
        return p.length ? "file://" + p : "";
    }
    readonly property real _prefW: root._kind === "sticker" ? 140 : 240
    readonly property real _aspect: (root.media && root.media.width > 0 && root.media.height > 0) ? (root.media.height / root.media.width) : 0.75
    readonly property real _imgW: root._prefW
    readonly property real _imgH: Math.max(80, Math.min(320, Math.round(root._imgW * root._aspect)))

    function sizeText(bytes): string {
        const n = Number(bytes || 0);
        if (!(n > 0))
            return "";
        if (n < 1024)
            return n + " B";
        if (n < 1024 * 1024)
            return Math.round(n / 1024) + " KB";
        return (n / (1024 * 1024)).toFixed(1) + " MB";
    }

    function _label(): string {
        const k = root._kind;
        if (k === "image")
            return "Foto";
        if (k === "video")
            return "Vídeo";
        if (k === "audio")
            return "Áudio";
        if (k === "document")
            return "Documento";
        if (k === "sticker")
            return "Figurinha";
        if (k === "location")
            return "Localização";
        if (k === "contact")
            return "Contato";
        return "Mensagem";
    }

    function _icon(): string {
        const k = root._kind;
        if (k === "document")
            return "description";
        if (k === "location")
            return "location_on";
        if (k === "contact")
            return "person";
        if (k === "sticker")
            return "sticky_note_2";
        return "image";
    }

    function _rowTitle(): string {
        if (root._pending && root.upload && String(root.upload.name || "").length)
            return String(root.upload.name);
        if (root._kind === "document" && root.text.length)
            return root.text;
        if (root._kind === "audio" && root.media && Number(root.media.duration) > 0) {
            const secs = Math.round(Number(root.media.duration));
            return Math.floor(secs / 60) + ":" + ("0" + (secs % 60)).slice(-2);
        }
        return root._label();
    }

    function _activate(): void {
        if (root._busy || root._pending)
            return;
        root._error = false;
        if (root._path.length) {
            WhatsAppClient.openPath(root._path);
            return;
        }
        root._busy = true;
        WhatsAppClient.downloadMedia(root.chat, root.messageId, function (media, err) {
            root._busy = false;
            if (err || !media || !String(media.path || "").length) {
                root._error = true;
                return;
            }
            WhatsAppClient.openPath(media.path);
        });
    }

    implicitWidth: root._framed ? root._imgW : 220
    implicitHeight: root._framed ? root._imgH : 44

    // -------------------------------------------------------------- //
    // Imagem / figurinha / vídeo (thumb)
    // -------------------------------------------------------------- //
    StyledClippingRect {
        anchors.fill: parent
        visible: root._framed
        radius: root._kind === "sticker" ? Tokens.rounding.small : Tokens.rounding.medium
        color: root.fromMe ? Qt.alpha(Colours.palette.m3onPrimaryContainer, 0.12) : Colours.tPalette.m3surfaceContainerHighest

        Image {
            anchors.fill: parent
            visible: root._hasImage
            source: root._imageSource
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: true
            sourceSize: Qt.size(Math.round(width * 2), Math.round(height * 2))
        }

        Column {
            anchors.centerIn: parent
            visible: !root._hasImage
            spacing: Tokens.spacing.extraSmall

            MaterialIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root._kind === "video" ? "videocam" : (root._kind === "sticker" ? "sticky_note_2" : "image")
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.extraLarge
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root._label()
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.small
            }
        }

        // Play (vídeo)
        MaterialIcon {
            anchors.centerIn: parent
            visible: root._kind === "video" && root._hasImage && !root._pending
            text: "play_circle"
            color: Qt.rgba(0, 0, 0, 0.65)
            fontStyle: Tokens.font.icon.builders.large.scale(1.6).build()
        }

        // Scrim de envio
        StyledRect {
            anchors.fill: parent
            visible: root._sending
            color: Qt.alpha(Colours.palette.m3scrim, 0.45)
        }

        LoadingIndicator {
            anchors.centerIn: parent
            visible: root._busy || (root._sending && root._framed)
            implicitSize: 30
        }
    }

    // -------------------------------------------------------------- //
    // Linha (áudio / documento / localização / contato)
    // -------------------------------------------------------------- //
    Row {
        anchors.fill: parent
        visible: !root._framed
        spacing: Tokens.spacing.small

        MaterialIcon {
            anchors.verticalCenter: parent.verticalCenter
            text: root._kind === "audio" ? "play_circle" : root._icon()
            color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3primary
            fontStyle: Tokens.font.icon.large
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - Tokens.font.icon.large.pointSize - Tokens.spacing.small - (root._pending ? 34 : 0)

            StyledText {
                width: parent.width
                text: root._rowTitle()
                color: root.fromMe ? Colours.palette.m3onPrimaryContainer : Colours.palette.m3onSurface
                font: Tokens.font.body.small
                elide: Text.ElideMiddle
                maximumLineCount: 1
            }

            StyledText {
                width: parent.width
                visible: root._pending ? true : root.sizeText(root.media ? root.media.size : 0).length > 0
                text: {
                    if (root._pending && root.upload)
                        return root.sizeText(root.upload.size) + (root._sending && root._pct > 0 ? " · " + root._pct + "%" : "");
                    return root.sizeText(root.media ? root.media.size : 0);
                }
                color: root.fromMe ? Qt.alpha(Colours.palette.m3onPrimaryContainer, 0.8) : Colours.palette.m3onSurfaceVariant
                font: Tokens.font.label.small
            }
        }
    }

    LoadingIndicator {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !root._framed && (root._busy || root._sending)
        implicitSize: 22
    }

    // Clique (abre/baixa). Fica desabilitado durante o envio.
    MouseArea {
        anchors.fill: parent
        enabled: !root._pending
        cursorShape: enabled ? Qt.PointingHandCursor : undefined
        onClicked: root._activate()
    }

    // Barra de progresso fina (imagem/vídeo em envio)
    StyledRect {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root._sending && root._framed
        implicitHeight: 3
        color: Qt.alpha(Colours.palette.m3scrim, 0.4)

        StyledRect {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.max(0, Math.min(1, root._pct / 100))
            color: Colours.palette.m3primary
        }
    }

    // Falha de envio: scrim + ações
    StyledRect {
        anchors.fill: parent
        visible: root._failed
        radius: root._framed ? (root._kind === "sticker" ? Tokens.rounding.small : Tokens.rounding.medium) : Tokens.rounding.small
        color: Qt.alpha(Colours.palette.m3scrim, 0.55)

        Column {
            anchors.centerIn: parent
            spacing: Tokens.spacing.extraSmall

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Falha ao enviar"
                color: Colours.palette.m3error
                font: Tokens.font.label.small
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Tokens.spacing.extraSmall

                StyledRect {
                    implicitWidth: retryLabel.implicitWidth + Tokens.spacing.small * 2
                    implicitHeight: retryLabel.implicitHeight + Tokens.spacing.extraSmall
                    radius: Tokens.rounding.small
                    color: Colours.palette.m3primary

                    StyledText {
                        id: retryLabel

                        anchors.centerIn: parent
                        text: "Tentar de novo"
                        color: Colours.palette.m3onPrimary
                        font: Tokens.font.label.small
                    }

                    StateLayer {
                        radius: parent.radius
                        onClicked: WhatsAppClient.retryUpload(root.upload ? root.upload.tempId : root.messageId)
                    }
                }

                StyledRect {
                    implicitWidth: discardLabel.implicitWidth + Tokens.spacing.small * 2
                    implicitHeight: discardLabel.implicitHeight + Tokens.spacing.extraSmall
                    radius: Tokens.rounding.small
                    color: Colours.tPalette.m3surfaceContainerHighest

                    StyledText {
                        id: discardLabel

                        anchors.centerIn: parent
                        text: "Descartar"
                        color: Colours.palette.m3onSurface
                        font: Tokens.font.label.small
                    }

                    StateLayer {
                        radius: parent.radius
                        onClicked: WhatsAppClient.discardUpload(root.upload ? root.upload.tempId : root.messageId)
                    }
                }
            }
        }
    }

    // Falha de download (mídia recebida)
    StyledText {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.bottomMargin: -Tokens.spacing.medium
        visible: root._error
        text: "Falha ao baixar · tentar de novo"
        color: Colours.palette.m3error
        font: Tokens.font.label.small
    }
}
