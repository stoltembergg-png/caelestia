// MessageComposer — anexo (1 arquivo) + faixa de resposta + caixa de texto.
//
// A caixa é um "pill" nativo (StyledRect + TextFieldBase + placeholder próprio,
// no estilo do SearchBar do shell). Anexo via zenity (fallback FileDialog),
// preview acima e envio por Enter/botão (texto ou mídia com legenda).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras
import qs.extras.whatsapp

ColumnLayout {
    id: root

    readonly property bool compact: WhatsAppSettings.getBool("compactMode", false)
    readonly property real _pad: root.compact ? Tokens.padding.extraSmall : Tokens.padding.small

    spacing: root.compact ? Tokens.spacing.extraSmall : Tokens.spacing.small

    // ------------------------------------------------------------------ //
    // Estado do anexo
    // ------------------------------------------------------------------ //
    property string stagedPath: ""
    property string stagedName: ""
    property string stagedKind: ""
    property string stagedMime: ""
    property real stagedSize: 0
    property string stagedError: ""
    property string _probeCandidate: ""
    property bool _hasZenity: false
    readonly property bool staged: root.stagedPath.length > 0

    function _basename(path): string {
        const p = String(path || "");
        const i = p.lastIndexOf("/");
        return i >= 0 ? p.substring(i + 1) : p;
    }

    function _urlToPath(u): string {
        let s = String(u || "");
        if (s.startsWith("file://"))
            s = s.substring(7);
        try {
            s = decodeURIComponent(s);
        } catch (e) {
        }
        return s;
    }

    function _kindForMime(mime): string {
        const m = String(mime || "").toLowerCase();
        if (m.startsWith("image/"))
            return "image";
        if (m.startsWith("video/"))
            return "video";
        if (m.startsWith("audio/"))
            return "audio";
        if (m.startsWith("application/") || m.startsWith("text/"))
            return "document";
        return "";
    }

    function _kindIcon(kind): string {
        if (kind === "image")
            return "image";
        if (kind === "video")
            return "videocam";
        if (kind === "audio")
            return "audiotrack";
        return "description";
    }

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

    function startPick(): void {
        if (root._hasZenity)
            picker.running = true;
        else
            fallbackDialog.open();
    }

    function stageUrl(u): void {
        root.stagePath(root._urlToPath(u));
    }

    function stagePath(path): void {
        const p = String(path || "").trim();
        if (!p.length)
            return;
        root.stagedError = "";
        root._probeCandidate = p;
        probe.command = ["sh", "-c", 'stat -c %s "$1" 2>/dev/null; file -b --mime-type "$1" 2>/dev/null', "sh", p];
        probe.running = false;
        probe.running = true;
    }

    function _applyProbe(output): void {
        const lines = String(output || "").trim().split(/\n/);
        const size = parseInt(lines[0] || "0", 10) || 0;
        const mime = String(lines[1] || "application/octet-stream").trim().toLowerCase();
        const kind = root._kindForMime(mime);
        if (!(size > 0)) {
            root.stagedError = I18n.t("whatsapp.composer.read_file_failed");
            return;
        }
        if (size > 100 * 1024 * 1024) {
            root.stagedError = I18n.t("whatsapp.composer.file_too_large");
            return;
        }
        if (!kind.length) {
            root.stagedError = I18n.t("whatsapp.composer.unsupported_file");
            return;
        }
        root.stagedPath = root._probeCandidate;
        root.stagedName = root._basename(root._probeCandidate);
        root.stagedKind = kind;
        root.stagedMime = mime;
        root.stagedSize = size;
        root.stagedError = "";
        Qt.callLater(() => input.forceActiveFocus());
    }

    function cancelStaged(): void {
        root.stagedPath = "";
        root.stagedName = "";
        root.stagedKind = "";
        root.stagedMime = "";
        root.stagedSize = 0;
        root.stagedError = "";
        input.text = "";
    }

    function submit(): void {
        if (root.staged) {
            const ok = WhatsAppClient.sendMedia(root.stagedPath, root.stagedKind, root.stagedMime, root.stagedSize, input.text);
            if (ok)
                root.cancelStaged();
            else
                root.stagedError = WhatsAppClient.lastError;
            return;
        }
        const body = input.text;
        if (!body.trim().length)
            return;
        if (WhatsAppClient.send(body))
            input.text = "";
    }

    // ------------------------------------------------------------------ //
    // Picker (zenity; fallback FileDialog)
    // ------------------------------------------------------------------ //
    Process {
        id: zenityCheck

        command: ["sh", "-c", "command -v zenity"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: root._hasZenity = text.trim().length > 0
        }
    }

    Process {
        id: picker

        command: ["zenity", "--file-selection", "--title=" + I18n.t("whatsapp.composer.file_title")]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim();
                if (p.length)
                    root.stagePath(p);
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: code => {
            if (code === 127)
                fallbackDialog.open();
        }
        // qmllint enable signal-handler-parameters
    }

    Process {
        id: probe

        command: []
        stdout: StdioCollector {
            onStreamFinished: root._applyProbe(text)
        }
    }

    FileDialog {
        id: fallbackDialog

        title: I18n.t("whatsapp.composer.file_title")
        fileMode: FileDialog.OpenFile
        onAccepted: root.stageUrl(selectedFile)
    }

    // ------------------------------------------------------------------ //
    // Faixa de citação
    // ------------------------------------------------------------------ //
    StyledClippingRect {
        Layout.fillWidth: true
        visible: WhatsAppClient.replyToId.length > 0
        implicitHeight: replyCol.implicitHeight + Tokens.spacing.small
        radius: Tokens.rounding.small
        color: Colours.tPalette.m3surfaceContainer

        StyledRect {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 2
            color: Colours.palette.m3primary
        }

        Column {
            id: replyCol

            anchors.left: parent.left
            anchors.leftMargin: Tokens.spacing.small
            anchors.right: replyClose.left
            anchors.rightMargin: Tokens.spacing.extraSmall
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            StyledText {
                width: parent.width
                text: WhatsAppClient.replyToFromMe ? I18n.t("whatsapp.message.you") : WhatsAppClient.replyToName
                color: Colours.palette.m3primary
                font: Tokens.font.label.small
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            StyledText {
                width: parent.width
                text: WhatsAppClient.replyToText.length > 0 ? WhatsAppClient.replyToText : I18n.t("whatsapp.message.quoted")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }

        IconButton {
            id: replyClose

            anchors.right: parent.right
            anchors.rightMargin: Tokens.spacing.extraSmall
            anchors.verticalCenter: parent.verticalCenter
            type: IconButton.Text
            icon: "close"
            onClicked: WhatsAppClient.clearReply()
        }
    }

    // ------------------------------------------------------------------ //
    // Preview/confirmacão do anexo
    // ------------------------------------------------------------------ //
    StyledClippingRect {
        Layout.fillWidth: true
        visible: root.staged || root.stagedError.length > 0
        implicitHeight: previewCol.implicitHeight + Tokens.spacing.small * 2
        radius: Tokens.rounding.small
        color: Colours.tPalette.m3surfaceContainer

        RowLayout {
            id: previewCol

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Tokens.spacing.small
            anchors.rightMargin: Tokens.spacing.extraSmall
            spacing: Tokens.spacing.small

            StyledClippingRect {
                Layout.alignment: Qt.AlignVCenter
                visible: root.staged
                implicitWidth: 36
                implicitHeight: 36
                radius: Tokens.rounding.small
                color: Colours.tPalette.m3surfaceContainerHighest

                Image {
                    anchors.fill: parent
                    visible: root.stagedKind === "image"
                    source: WhatsAppClient.mediaSource(root.stagedPath)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }

                MaterialIcon {
                    anchors.centerIn: parent
                    visible: root.stagedKind !== "image"
                    text: root._kindIcon(root.stagedKind)
                    color: Colours.palette.m3onSurfaceVariant
                    fontStyle: Tokens.font.icon.medium
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: root.staged ? root.stagedName : I18n.t("whatsapp.composer.attachment")
                    color: Colours.palette.m3onSurface
                    font: Tokens.font.body.small
                    elide: Text.ElideMiddle
                    maximumLineCount: 1
                }

                StyledText {
                    Layout.fillWidth: true
                    text: root.stagedError.length > 0 ? root.stagedError : root.sizeText(root.stagedSize)
                    visible: text.length > 0
                    color: root.stagedError.length > 0 ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.label.small
                    elide: Text.ElideRight
                    maximumLineCount: 1
                }
            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                type: IconButton.Text
                icon: "close"
                onClicked: root.cancelStaged()
            }
        }
    }

    // ------------------------------------------------------------------ //
    // Caixa de texto (pill nativo)
    // ------------------------------------------------------------------ //
    StyledRect {
        id: bar

        Layout.fillWidth: true
        // Foco sutil sem contorno: só um leve clareamento da superfície
        // (animado pelo Behavior on color do StyledRect).
        color: input.activeFocus ? Colours.tPalette.m3surfaceContainerHighest : Colours.tPalette.m3surfaceContainer
        radius: Tokens.rounding.extraLarge
        implicitHeight: row.implicitHeight + root._pad * 2

        RowLayout {
            id: row

            anchors.fill: parent
            anchors.margins: root._pad
            spacing: Tokens.spacing.extraSmall

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                type: IconButton.Text
                icon: "attach_file"
                disabled: !WhatsAppClient.loggedIn
                onClicked: root.startPick()
            }

            Item {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                implicitHeight: input.implicitHeight

                TextFieldBase {
                    id: input

                    anchors.fill: parent
                    leftPadding: 0
                    rightPadding: 0
                    topPadding: 0
                    bottomPadding: 0
                    color: Colours.palette.m3onSurface
                    font: Tokens.font.body.small
                    readOnly: !WhatsAppClient.loggedIn

                    onAccepted: root.submit()
                }

                StyledText {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.staged ? I18n.t("whatsapp.composer.caption_placeholder") : (WhatsAppClient.replyToId.length > 0 ? I18n.t("whatsapp.composer.reply_placeholder") : I18n.t("whatsapp.composer.message_placeholder"))
                    color: Colours.palette.m3onSurfaceVariant
                    font: input.font
                    opacity: input.text.length > 0 ? 0 : 1

                    Behavior on opacity {
                        Anim {
                            type: Anim.DefaultEffects
                        }
                    }
                }
            }

            IconButton {
                Layout.alignment: Qt.AlignVCenter
                type: IconButton.Filled
                icon: "send"
                disabled: !WhatsAppClient.loggedIn || (!root.staged && input.text.trim().length === 0)
                onClicked: root.submit()
            }
        }
    }

    Connections {
        target: WhatsAppClient

        function onCurrentChatChanged() {
            root.cancelStaged();
            if (WhatsAppClient.currentChat.length > 0)
                Qt.callLater(() => input.forceActiveFocus());
        }

        function onReplyToIdChanged() {
            if (WhatsAppClient.replyToId.length > 0 && !root.staged)
                Qt.callLater(() => input.forceActiveFocus());
        }
    }
}
