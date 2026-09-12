// MessageComposer — campo de texto + botão de enviar.
//
// Enter envia (o campo é de linha única), Shift+Enter também cai no mesmo
// caminho. Nada de protocolo aqui: só chama WhatsAppClient.send().

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components.controls
import qs.extras.whatsapp

RowLayout {
    id: root

    spacing: Tokens.spacing.small

    function submit(): void {
        const body = input.text;
        if (!body.trim().length)
            return;
        if (WhatsAppClient.send(body))
            input.text = "";
    }

    StyledTextField {
        id: input

        Layout.fillWidth: true
        type: StyledTextField.Filled
        placeholderText: "Mensagem"
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

    Connections {
        target: WhatsAppClient

        function onCurrentChatChanged() {
            if (WhatsAppClient.currentChat.length > 0)
                Qt.callLater(() => input.forceActiveFocus());
        }
    }
}
