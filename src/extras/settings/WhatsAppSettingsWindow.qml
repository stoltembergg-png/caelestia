// Novo para o Caelestia (derivado do fork Caelestia Shell, AGPL-3.0).
// [L4] Fallback standalone dos Ajustes do WhatsApp: uma FloatingWindow nativa que
// reutiliza o MESMO conteúdo da página (WhatsAppPage) sem passar pela janela/stack
// do Nexus. É aberta pelo IPC `extras openWhatsAppSettings` e pelo atalho
// `whatsappsettings` (definidos em ../Extras.qml); Esc fecha. O chamador controla a
// visibilidade pela propriedade herdada `visible` e pelos métodos open/close/toggle.

import QtQuick
import Quickshell
import Caelestia.Config
import qs.modules.nexus
import qs.services

FloatingWindow {
    id: win

    readonly property real panelWidth: Tokens.sizes.utilities.width
    readonly property real panelHeight: 640

    // PageBase (raiz de WhatsAppPage) exige um NexusState; usamos um estado local
    // mínimo, sem navegação/stack do Nexus (a página não abre subpáginas).
    NexusState {
        id: waNState
    }

    function open(): void {
        win.visible = true;
    }

    function close(): void {
        win.visible = false;
    }

    function toggle(): void {
        win.visible = !win.visible;
    }

    title: qsTr("Ajustes do WhatsApp")
    color: "transparent"
    surfaceFormat.opaque: false
    implicitWidth: panelWidth
    implicitHeight: panelHeight
    minimumSize.width: panelWidth
    minimumSize.height: 360

    // Fundo nativo (m3) com o raio extraLarge do tema. O container dimensiona a
    // WhatsAppPage; o scroll é o flickable interno do PageBase (sem Flickable aninhado).
    Rectangle {
        anchors.fill: parent
        color: Colours.tPalette.m3surfaceContainer
        radius: Tokens.rounding.extraLarge
        clip: true

        WhatsAppPage {
            id: waPage

            anchors.fill: parent
            anchors.margins: Tokens.padding.large
            nState: waNState
        }
    }

    Shortcut {
        sequence: "Escape"
        enabled: win.visible
        onActivated: win.close()
    }
}
