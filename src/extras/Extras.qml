// Portado de Serpantinum: src/quickshell/Shell.qml / Main.qml (AGPL-3.0)
// Entry do módulo extras: instancia os hosts QuickActions, Dock, NoLimits e WhatsApp,
// expõe o IPC target "extras" e os atalhos globais correspondentes.
// Estado: FloatingController (quick actions) / shim Config (dock) / singleton NoLimits /
// instância local do WhatsAppOverlay.

import QtQuick
import Quickshell.Io
import qs.extras
import qs.components.misc
import "quickactions"
import "dock"
import "nolimits"
import "whatsapp"

Item {
    id: root

    QuickActions {}

    Dock {}

    WhatsAppOverlay {
        id: whatsappOverlay
    }

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

    function toggleNoLimits() {
        NoLimits.toggle();
    }

    function setNoLimitsView(view) {
        NoLimits.show(view);
    }

    function toggleWhatsApp() {
        whatsappOverlay.toggle();
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

        function toggleNoLimits(): void {
            root.toggleNoLimits();
        }

        function setNoLimitsView(view: string): void {
            root.setNoLimitsView(view);
        }

        function toggleWhatsApp(): void {
            root.toggleWhatsApp();
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

    CustomShortcut {
        name: "nolimits"
        description: "Toggle No Limits (KodexBar) panel"
        onPressed: root.toggleNoLimits()
    }

    CustomShortcut {
        name: "whatsapp"
        description: "Toggle WhatsApp panel"
        onPressed: root.toggleWhatsApp()
    }
}
