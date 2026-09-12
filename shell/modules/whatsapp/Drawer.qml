// Drawer — painel nativo do WhatsApp (full-height, ancorado à esquerda).
//
// Contrato congelado consumido pelo patch do core (modules/drawers/Panels.qml,
// ContentWindow.qml, Regions.qml e Interactions.qml):
//   required property ShellScreen screen
//   property var screenState
//   property real offsetScale       // 0 = visível, 1 = oculto (animado)
//   open() / close() / scheduleHide()
//
// Sem fundo próprio: o blob do core (PanelBg/BlobGroup) desenha atrás e o aro
// funde as bordas. Aqui vivemos apenas o conteúdo (WhatsAppPanel), a animação
// de entrada/saída e o fecho por Esc.

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.components
import qs.services
import qs.extras.whatsapp

Item {
    id: root

    required property ShellScreen screen

    // Recebido pelo patch do core; mantido para futura observação.
    property var screenState

    // O conteúdo do drawer é carregado por um Loader lazy. Tocar no singleton
    // aqui garante que ele exista (e o socket IPC suba) no boot do shell, e não
    // só na primeira abertura — assim o estado de auth e as conversas já estão
    // prontos quando o painel aparece.
    readonly property bool clientAlive: WhatsAppClient.socketConnected || WhatsAppClient.paired

    // ------------------------------------------------------------------ //
    // API / geometria (contrato congelado)
    // ------------------------------------------------------------------ //
    // 0 = totalmente visível, 1 = totalmente recolhido.
    property bool opened: false
    property real offsetScale: root.opened ? 0 : 1

    implicitWidth: Math.round(Math.max(380, Math.min(440, root.screen.width * 0.34)))
    implicitHeight: root.screen.height

    visible: root.offsetScale < 1
    opacity: 1 - root.offsetScale
    anchors.leftMargin: (-root.implicitWidth - 5) * root.offsetScale

    Behavior on offsetScale {
        Anim {
            type: Anim.DefaultSpatial
        }
    }

    readonly property bool focused: {
        const mon = Hypr.focusedMonitor;
        return mon !== null && mon !== undefined && mon.name === root.screen.name;
    }

    // ------------------------------------------------------------------ //
    // Interação / ciclo de vida
    // ------------------------------------------------------------------ //
    function open(): void {
        root.opened = true;
        WhatsAppState.visible = true;
    }

    function close(): void {
        hideTimer.stop();
        root.opened = false;
        WhatsAppState.visible = false;
    }

    function scheduleHide(): void {
        if (!root.opened)
            return;
        hideTimer.restart();
    }

    function toggle(): void {
        if (root.opened)
            root.close();
        else
            root.open();
    }

    Timer {
        id: hideTimer

        // Atraso configurável no JSON próprio do módulo.
        interval: Math.max(50, WhatsAppSettings.getInt("hideDelay", 300))
        repeat: false
        onTriggered: root.close()
    }

    // Pedidos globais só são atendidos pelo monitor focado.
    Connections {
        target: WhatsAppState

        function onShowRequested(): void {
            if (root.focused)
                root.open();
        }

        function onHideRequested(): void {
            if (root.focused)
                root.close();
        }
    }

    Shortcut {
        enabled: root.visible
        sequence: "Escape"
        onActivated: root.close()
    }

    // ------------------------------------------------------------------ //
    // Conteúdo (lazy)
    // ------------------------------------------------------------------ //
    Loader {
        id: content

        anchors.fill: parent
        active: root.opened || root.offsetScale < 1
        asynchronous: true

        sourceComponent: WhatsAppPanel {
            screen: root.screen
            drawer: root
        }
    }
}
