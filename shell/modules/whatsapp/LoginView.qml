// LoginView — pareamento por QR.
//
// O QR chega pronto do daemon como PNG em base64 (evento `auth.qr`), exposto
// por WhatsAppClient.qrPng como data URI. Enquanto não há QR, mostramos o
// convite para conectar e, em seguida, um estado de espera.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras.whatsapp

Item {
    id: root

    signal generate()

    readonly property bool hasQr: WhatsAppClient.qrPng.length > 0

    property bool _autoStarted: false

    function start(): void {
        root._autoStarted = true;
        root.generate();
    }

    // Aguarda o `status` inicial: só gera o QR quando o daemon confirma que
    // precisa de pareamento (evita `auth.start` prematuro).
    Connections {
        target: WhatsAppClient

        function onAuthStateChanged() {
            if (!root._autoStarted && !WhatsAppClient.loggedIn && WhatsAppClient.authState === "needs_pairing")
                root.start();
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width, 320)
        spacing: Tokens.spacing.large

        StyledText {
            Layout.fillWidth: true
            visible: !root.hasQr
            text: "Pareie seu WhatsApp"
            color: Colours.palette.m3onSurface
            font: Tokens.font.title.medium
            horizontalAlignment: Text.AlignHCenter
        }

        StyledText {
            Layout.fillWidth: true
            visible: !root.hasQr
            text: "Abra o WhatsApp no celular, toque em Dispositivos conectados e aponte a câmera para o código."
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }

        // Cartão branco: o QR precisa de contraste claro para ser lido.
        StyledRect {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 240
            Layout.preferredHeight: 240
            visible: root.hasQr
            radius: Tokens.rounding.large
            color: "white"

            Image {
                anchors.fill: parent
                anchors.margins: Tokens.padding.small
                source: WhatsAppClient.qrPng
                fillMode: Image.PreserveAspectFit
                smooth: false
                mipmap: false
                asynchronous: true
                sourceSize: Qt.size(216, 216)
            }
        }

        Item {
            Layout.alignment: Qt.AlignHCenter
            visible: !root.hasQr
            implicitWidth: 48
            implicitHeight: 48

            LoadingIndicator {
                anchors.centerIn: parent
                implicitSize: 40
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: !root.hasQr
            text: "Gerando código…"
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            horizontalAlignment: Text.AlignHCenter
        }

        TextButton {
            Layout.alignment: Qt.AlignHCenter
            visible: !root.hasQr
            type: TextButton.Filled
            text: "Conectar dispositivo"
            onClicked: root.start()
        }

        TextButton {
            Layout.alignment: Qt.AlignHCenter
            visible: root.hasQr
            type: TextButton.Text
            text: "Gerar novo código"
            onClicked: root.start()
        }

        StyledText {
            Layout.fillWidth: true
            visible: WhatsAppClient.lastError.length > 0
            text: WhatsAppClient.lastError
            color: Colours.palette.m3error
            font: Tokens.font.label.small
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
        }
    }
}
