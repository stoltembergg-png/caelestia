// WhatsAppSettingsPage — página do Nexus para o módulo WhatsApp.
//
// Estado (conexão, conta, não lidas), ações (gerar QR, abrir drawer, logout com
// confirmação simples) e preferências persistidas por WhatsAppSettings no JSON
// próprio (~/.config/caelestia-whatsapp/settings.json), sem tocar no extras.json.
//
// É registrada no qmldir do módulo; a integração no PageRegistry/PageCompRegistry
// é feita pelo patch do Nexus (outra lane).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus.common
import qs.extras.whatsapp

PageBase {
    id: root

    title: qsTr("WhatsApp")

    readonly property bool paired: WhatsAppClient.paired

    property bool _confirmLogout: false

    function connectionLabel(): string {
        if (WhatsAppClient.connectionState === "connected")
            return qsTr("Conectado");
        if (WhatsAppClient.connectionState === "connecting")
            return qsTr("Conectando…");
        if (WhatsAppClient.connectionState === "needs_pairing")
            return qsTr("Não pareado");
        return qsTr("Offline");
    }

    function requestLogout(): void {
        if (!root._confirmLogout) {
            root._confirmLogout = true;
            logoutReset.restart();
            return;
        }
        root._confirmLogout = false;
        logoutReset.stop();
        WhatsAppClient.logout();
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        Timer {
            id: logoutReset

            interval: 3000
            repeat: false
            onTriggered: root._confirmLogout = false
        }

        // -------------------------------------------------------------- //
        // Estado
        // -------------------------------------------------------------- //
        SectionHeader {
            first: true
            text: qsTr("Estado")
        }

        InfoRow {
            first: true
            icon: root.paired ? "check_circle" : "link_off"
            iconColour: root.paired ? Colours.palette.m3success : Colours.palette.m3error
            label: qsTr("Conexão")
            value: root.connectionLabel()
        }

        InfoRow {
            icon: "account_circle"
            label: qsTr("Conta")
            value: WhatsAppClient.pushName.length > 0 ? WhatsAppClient.pushName : qsTr("—")
            subtext: WhatsAppClient.accountJid
        }

        InfoRow {
            last: true
            icon: "mark_chat_unread"
            label: qsTr("Mensagens não lidas")
            value: String(WhatsAppClient.unreadCount)
        }

        // -------------------------------------------------------------- //
        // Ações
        // -------------------------------------------------------------- //
        SectionHeader {
            text: qsTr("Ações")
        }

        RowButton {
            first: true
            visible: !root.paired
            icon: "qr_code_2"
            text: qsTr("Conectar por QR code")
            subtext: qsTr("Gerar um novo código de pareamento")
            onClicked: WhatsAppClient.startLogin()
        }

        RowButton {
            first: root.paired
            icon: "open_in_new"
            text: qsTr("Abrir painel")
            subtext: qsTr("Mostrar o drawer do WhatsApp")
            onClicked: WhatsAppState.show()
        }

        RowButton {
            last: true
            icon: "logout"
            text: root._confirmLogout ? qsTr("Confirmar logout") : qsTr("Sair")
            subtext: root._confirmLogout ? qsTr("Toque de novo para desconectar") : qsTr("Desvincular este dispositivo")
            disabled: !root.paired
            onClicked: root.requestLogout()
        }

        // -------------------------------------------------------------- //
        // Preferências
        // -------------------------------------------------------------- //
        SectionHeader {
            text: qsTr("Preferências")
        }

        ToggleRow {
            first: true
            text: qsTr("Notificações")
            subtext: qsTr("Avisar sobre novas mensagens recebidas")
            checked: WhatsAppSettings.getBool("notifications", true)
            onToggled: WhatsAppSettings.set("notifications", checked)
        }

        ToggleRow {
            last: true
            text: qsTr("Abrir ao passar o mouse")
            subtext: qsTr("Abrir o painel ao aproximar o cursor da borda da barra")
            checked: WhatsAppSettings.getBool("openOnHover", true)
            onToggled: WhatsAppSettings.set("openOnHover", checked)
        }

        StyledText {
            Layout.fillWidth: true
            Layout.topMargin: Tokens.spacing.small
            visible: WhatsAppClient.lastError.length > 0
            text: WhatsAppClient.lastError
            color: Colours.palette.m3error
            font: Tokens.font.label.small
            wrapMode: Text.Wrap
        }
    }
}
