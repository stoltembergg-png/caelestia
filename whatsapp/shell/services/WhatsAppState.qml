// WhatsAppState — estado lógico compartilhado do drawer nativo do WhatsApp.
//
// Registro: singleton no qmldir do módulo `qs.extras.whatsapp`.
// O badge da barra / a página do Nexus pedem `showRequested()`/`hideRequested()`
// e o Drawer (só no monitor focado) reage. `visible` espelha se há um drawer
// aberto no momento — leitura barata para consumidores externos.
//
// Sem lógica de protocolo aqui: apenas intenção de UI.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.components.misc
import qs.extras
import qs.extras.whatsapp

Singleton {
    id: root

    // Pedido de abrir/fechar vindo de qualquer consumidor (barra, atalho, Nexus).
    signal showRequested()
    signal hideRequested()

    // Espelho da visibilidade lógica do drawer (atualizado pelo Drawer).
    property bool visible: false

    function show(): void {
        root.showRequested();
    }

    function hide(): void {
        root.hideRequested();
    }

    function toggle(): void {
        if (root.visible)
            root.hideRequested();
        else
            root.showRequested();
    }

    // IPC `caelestia shell whatsapp …` / `qs -c caelestia ipc call whatsapp …`
    IpcHandler {
        target: "whatsapp"

        function toggle(): void {
            root.toggle();
        }

        function show(): void {
            root.show();
        }

        function hide(): void {
            root.hide();
        }

        function login(): void {
            WhatsAppClient.startLogin();
        }

        function logout(): void {
            WhatsAppClient.logout();
        }
    }

    // Atalho global `caelestia:whatsapp` (bind no Hyprland).
    CustomShortcut {
        name: "whatsapp"
        description: I18n.t("whatsapp.shortcuts.toggle_drawer")
        onPressed: root.toggle()
    }
}
