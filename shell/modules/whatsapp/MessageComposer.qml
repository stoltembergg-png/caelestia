// MessageComposer — faixa de resposta + campo de texto + botão de enviar.
//
// Enter envia (campo de linha única). Quando há alvo de resposta, mostra a
// citação (nome + trecho) com um X para cancelar; o envio usa message.reply.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras.whatsapp

ColumnLayout {
    id: root

    spacing: Tokens.spacing.extraSmall

    function submit(): void {
        const body = input.text;
        if (!body.trim().length)
            return;
        if (WhatsAppClient.send(body))
            input.text = "";
    }

    // Faixa de citação
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

    RowLayout {
        Layout.fillWidth: true
        spacing: Tokens.spacing.small

        StyledTextField {
            id: input

            Layout.fillWidth: true
            type: StyledTextField.Filled
            placeholderText: WhatsAppClient.replyToId.length > 0 ? "Responder…" : "Mensagem"
            leadingIcon: "chat_bubble"
            readOnly: !WhatsAppClient.loggedIn

            onAccepted: root.submit()
        }

        IconButton {
            type: IconButton.Filled
            icon: "send"
            disabled: !WhatsAppClient.loggedIn || input.text.trim().length === 0
            onClicked: root.submit()
        }
    }

    Connections {
        target: WhatsAppClient

        function onCurrentChatChanged() {
            if (WhatsAppClient.currentChat.length > 0)
                Qt.callLater(() => input.forceActiveFocus());
        }

        function onReplyToIdChanged() {
            if (WhatsAppClient.replyToId.length > 0)
                Qt.callLater(() => input.forceActiveFocus());
        }
    }
}
