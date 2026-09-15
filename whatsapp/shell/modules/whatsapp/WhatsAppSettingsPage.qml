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
import qs.extras
import qs.extras.whatsapp

PageBase {
    id: root

    title: I18n.t("whatsapp.settings.title")

    readonly property bool paired: WhatsAppClient.paired

    property bool _confirmLogout: false

    function connectionLabel(): string {
        if (WhatsAppClient.connectionState === "connected")
            return I18n.t("whatsapp.settings.connected");
        if (WhatsAppClient.connectionState === "connecting")
            return I18n.t("whatsapp.settings.connecting");
        if (WhatsAppClient.connectionState === "needs_pairing")
            return I18n.t("whatsapp.settings.not_paired");
        return I18n.t("whatsapp.settings.offline");
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
            text: I18n.t("whatsapp.settings.status")
        }

        InfoRow {
            first: true
            icon: root.paired ? "check_circle" : "link_off"
            iconColour: root.paired ? Colours.palette.m3success : Colours.palette.m3error
            label: I18n.t("whatsapp.settings.connection")
            value: root.connectionLabel()
        }

        InfoRow {
            icon: "account_circle"
            label: I18n.t("whatsapp.settings.account")
            value: WhatsAppClient.pushName.length > 0 ? WhatsAppClient.pushName : I18n.t("whatsapp.settings.no_account")
            subtext: WhatsAppClient.accountJid
        }

        InfoRow {
            last: true
            icon: "mark_chat_unread"
            label: I18n.t("whatsapp.settings.unread")
            value: String(WhatsAppClient.unreadCount)
        }

        // -------------------------------------------------------------- //
        // Ações
        // -------------------------------------------------------------- //
        SectionHeader {
            text: I18n.t("whatsapp.settings.actions")
        }

        RowButton {
            first: true
            visible: !root.paired
            icon: "qr_code_2"
            text: I18n.t("whatsapp.settings.connect_qr")
            subtext: I18n.t("whatsapp.settings.connect_qr_hint")
            onClicked: WhatsAppClient.startLogin()
        }

        RowButton {
            first: root.paired
            icon: "open_in_new"
            text: I18n.t("whatsapp.settings.open_panel")
            subtext: I18n.t("whatsapp.settings.open_panel_hint")
            onClicked: WhatsAppState.show()
        }

        RowButton {
            last: true
            icon: "logout"
            text: root._confirmLogout ? I18n.t("whatsapp.settings.confirm_logout") : I18n.t("whatsapp.settings.logout")
            subtext: root._confirmLogout ? I18n.t("whatsapp.settings.confirm_logout_hint") : I18n.t("whatsapp.settings.unlink_device")
            disabled: !root.paired
            onClicked: root.requestLogout()
        }

        // -------------------------------------------------------------- //
        // Preferências
        // -------------------------------------------------------------- //
        SectionHeader {
            text: I18n.t("whatsapp.settings.preferences")
        }

        ToggleRow {
            first: true
            text: I18n.t("whatsapp.settings.notifications")
            subtext: I18n.t("whatsapp.settings.notifications_desc")
            checked: WhatsAppSettings.getBool("notifications", true)
            onToggled: WhatsAppSettings.set("notifications", checked)
        }

        ToggleRow {
            text: I18n.t("whatsapp.settings.open_on_hover")
            subtext: I18n.t("whatsapp.settings.open_on_hover_desc")
            checked: WhatsAppSettings.getBool("openOnHover", true)
            onToggled: WhatsAppSettings.set("openOnHover", checked)
        }

        ToggleRow {
            last: true
            text: I18n.t("whatsapp.settings.compact_mode")
            subtext: I18n.t("whatsapp.settings.compact_mode_desc")
            checked: WhatsAppSettings.getBool("compactMode", false)
            onToggled: WhatsAppSettings.set("compactMode", checked)
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
