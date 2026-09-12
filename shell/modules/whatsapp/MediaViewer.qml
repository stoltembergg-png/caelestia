// MediaViewer — visualizador de mídia em overlay (layer-shell), sem depender de
// associação de arquivo do sistema. Fundo escurecido; fecha com clique ou Esc;
// zoom simples com a roda do mouse.

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.services
import qs.extras.whatsapp

// qmllint disable uncreatable-type
PanelWindow {
// qmllint enable uncreatable-type
    id: viewer

    // `screen` é herdado de WindowInterface (o Drawer injeta o ShellScreen).
    // Só o monitor focado exibe o overlay (evita abrir em todas as telas).
    required property bool active

    readonly property bool shown: viewer.active && WhatsAppClient.viewerVisible
    property real zoom: 1

    visible: viewer.shown
    color: "transparent"
    WlrLayershell.namespace: "caelestia-whatsapp-viewer"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: viewer.shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    WlrLayershell.exclusionMode: ExclusionMode.Ignore

    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true

    onShownChanged: {
        if (!viewer.shown)
            viewer.zoom = 1;
    }

    StyledRect {
        anchors.fill: parent
        color: Qt.alpha(Colours.palette.m3scrim, 0.85)

        MouseArea {
            anchors.fill: parent
            onClicked: WhatsAppClient.closeViewer()
        }

        Image {
            id: image

            anchors.centerIn: parent
            width: parent.width * 0.9
            height: parent.height * 0.9
            source: WhatsAppClient.mediaSource(WhatsAppClient.viewerPath)
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            cache: false
            smooth: true
            scale: viewer.zoom

            Behavior on scale {
                Anim {
                    type: Anim.FastEffects
                }
            }
        }

        IconButton {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: Tokens.padding.large
            type: IconButton.Tonal
            icon: "close"
            onClicked: WhatsAppClient.closeViewer()
        }

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
                const delta = event.angleDelta.y > 0 ? 0.12 : -0.12;
                viewer.zoom = Math.max(0.4, Math.min(5, viewer.zoom + delta));
            }
        }
    }

    Shortcut {
        sequence: "Escape"
        enabled: viewer.shown
        onActivated: WhatsAppClient.closeViewer()
    }
}
