// Portado de Serpantinum: src/quickshell/whatsapp/WhatsAppPopup.qml (AGPL-3.0)
// Host novo (não existe equivalente no Serpantinum): StyledWindow por tela,
// 940x500 top-center, backdrop que fecha, Esc fecha e só a tela focada interage.
// O WebEngineProfile é ÚNICO no processo (storageName não pode se repetir por tela).
import QtQuick
import Quickshell
import Quickshell.Wayland
import QtWebEngine
import qs.services
import qs.components.containers
import qs.extras

Scope {
    id: root

    property bool visible: false

    function toggle(): void {
        root.visible = !root.visible;
    }

    function show(): void {
        root.visible = true;
    }

    function hide(): void {
        root.visible = false;
    }

    WebEngineProfile {
        id: waProfile

        storageName: "serpantinum-whatsapp-v2"
        offTheRecord: false
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    }

    Variants {
        model: Screens.screens

        StyledWindow {
            id: win

            required property ShellScreen modelData
            screen: modelData
            name: "extras-whatsapp"

            readonly property bool focused: {
                const mon = Hypr.focusedMonitor;
                return !mon || mon.name === win.screen.name;
            }

            function s(val) {
                return Scaler.s(val);
            }

            visible: root.visible && win.focused
            color: "transparent"

            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.exclusionMode: ExclusionMode.Ignore
            WlrLayershell.keyboardFocus: (root.visible && win.focused) ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

            anchors.top: true
            anchors.bottom: true
            anchors.left: true
            anchors.right: true

            // Backdrop transparente: clique fora do painel fecha.
            MouseArea {
                anchors.fill: parent
                onClicked: root.hide()
            }

            WhatsAppPanel {
                id: panel

                profile: waProfile
                width: Math.min(win.width - win.s(32), win.s(940))
                height: win.s(500)
                x: (win.width - width) / 2
                y: win.s(52)
                visible: root.visible && win.focused
            }

            Shortcut {
                sequence: "Escape"
                enabled: win.visible
                onActivated: root.hide()
            }
        }
    }
}
