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
}
