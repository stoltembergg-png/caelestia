// MessageComposer — anexo (1 arquivo) + faixa de resposta + campo + enviar.
//
// Anexo: botão de clipe usa `zenity --file-selection` (stdout capturado por
// Process); se o zenity não existir, cai para QtQuick.Dialogs.FileDialog.
// Preview/confirmacão acima do input (thumb/nome/tamanho + legenda + X).
// Sem anexo, o comportamento de texto/reply permanece.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Dialogs
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras.whatsapp

ColumnLayout {
    id: root

    spacing: Tokens.spacing.extraSmall

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

    // Ponto único de entrada (picker, drop e FileDialog).
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
            root.stagedError = "Não foi possível ler o arquivo";
            return;
        }
        if (size > 100 * 1024 * 1024) {
            root.stagedError = "Arquivo maior que 100 MB";
            return;
        }
        if (!kind.length) {
            root.stagedError = "Tipo de arquivo não suportado";
            return;
        }
        root.stagedPath = root._probeCandidate;
        root.stagedName = root._basename(root._probeCandidate);
        root.stagedKind = kind;
        root.stagedMime = mime;
        root.stagedSize = size;
        root.stagedError = "";
        Qt.callLater(() => captionField.forceActiveFocus());
    }

    function cancelStaged(): void {
        root.stagedPath = "";
        root.stagedName = "";
        root.stagedKind = "";
        root.stagedMime = "";
        root.stagedSize = 0;
        root.stagedError = "";
        captionField.text = "";
    }

    function submit(): void {
        if (root.staged) {
            const ok = WhatsAppClient.sendMedia(root.stagedPath, root.stagedKind, root.stagedMime, root.stagedSize, captionField.text);
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

        command: ["zenity", "--file-selection", "--title=Enviar arquivo"]
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim();
                if (p.length)
                    root.stagePath(p);
            }
        }
        // qmllint disable signal-handler-parameters
        // O enum QProcess::ExitStatus não está no qmltypes; é válido em runtime.
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

        title: "Enviar arquivo"
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
                text: WhatsAppClient.replyToFromMe ? "Você" : WhatsAppClient.replyToName
                color: Colours.palette.m3primary
                font: Tokens.font.label.small
                elide: Text.ElideRight
                maximumLineCount: 1
            }

            StyledText {
                width: parent.width
                text: WhatsAppClient.replyToText.length > 0 ? WhatsAppClient.replyToText : "Mensagem citada"
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
        implicitHeight: previewCol.implicitHeight + Tokens.spacing.medium * 2
        radius: Tokens.rounding.small
        color: Colours.tPalette.m3surfaceContainer

        ColumnLayout {
            id: previewCol

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Tokens.spacing.medium
            anchors.rightMargin: Tokens.spacing.small
            spacing: Tokens.spacing.extraSmall

            RowLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small

                StyledClippingRect {
                    Layout.alignment: Qt.AlignVCenter
                    visible: root.staged
                    implicitWidth: 40
                    implicitHeight: 40
                    radius: Tokens.rounding.small
                    color: Colours.tPalette.m3surfaceContainerHighest

                    Image {
                        anchors.fill: parent
                        visible: root.stagedKind === "image"
                        source: root.stagedPath.length ? "file://" + root.stagedPath : ""
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
                        text: root.staged ? root.stagedName : "Anexo"
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

            StyledTextField {
                id: captionField

                Layout.fillWidth: true
                visible: root.staged
                type: StyledTextField.Filled
                placeholderText: "Legenda…"
                leadingIcon: "text_fields"
                onAccepted: root.submit()
            }
        }
    }

    // ------------------------------------------------------------------ //
    // Input + ações
    // ------------------------------------------------------------------ //
    RowLayout {
        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        StyledTextField {
            id: input

            Layout.fillWidth: true
            visible: !root.staged
            type: StyledTextField.Filled
            placeholderText: WhatsAppClient.replyToId.length > 0 ? "Responder…" : "Mensagem"
            leadingIcon: "chat_bubble"
            readOnly: !WhatsAppClient.loggedIn

            onAccepted: root.submit()
        }

        Item {
            Layout.fillWidth: true
            visible: root.staged
        }

        IconButton {
            type: IconButton.Text
            icon: "attach_file"
            disabled: !WhatsAppClient.loggedIn
            onClicked: root.startPick()
        }

        IconButton {
            type: IconButton.Filled
            icon: "send"
            disabled: !WhatsAppClient.loggedIn || (!root.staged && input.text.trim().length === 0)
            onClicked: root.submit()
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
