// Portado de Serpantinum: src/quickshell/Shell.qml / Main.qml (AGPL-3.0)
// Entry do módulo extras: instancia os hosts QuickActions (lane B) e Dock (lane C),
// expõe IPC target "extras" e os atalhos globais "quickactions"/"dock".
// Delega o estado a FloatingController (quick actions) e ao shim Config (dock).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.extras
import "quickactions"
import "dock"

Item {
    id: root

    QuickActions {}

    Dock {}

    function toggleQuickActions() {
        // O host decide qual aba abrir quando recebe tab vazio.
        FloatingController.show("");
    }

    function setQuickActionsTab(index) {
        FloatingController.setIndex(index);
    }

    function toggleDock() {
        const current = Config.getSetting("dock", {
            "enabled": true
        });
        const next = Object.assign({}, current);
        next.enabled = !(current && current.enabled !== false);
        Config.setSetting("dock", next);
    }

    IpcHandler {
        target: "extras"

        function toggleQuickActions(): void {
            root.toggleQuickActions();
        }

        function setQuickActionsTab(index: int): void {
            root.setQuickActionsTab(index);
        }

        function toggleDock(): void {
            root.toggleDock();
        }
    }

    CustomShortcut {
        name: "quickactions"
        description: "Toggle quick actions panel"
        onPressed: root.toggleQuickActions()
    }

    CustomShortcut {
        name: "dock"
        description: "Toggle dock"
        onPressed: root.toggleDock()
    }
}
