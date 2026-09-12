// Portado de Serpantinum: src/quickshell/Shell.qml / Main.qml (AGPL-3.0)
// Entry do módulo extras: instancia os hosts QuickActions, NoLimits e WhatsApp,
// o fallback standalone dos Ajustes da Dock e expõe o IPC target "extras" e os
// atalhos globais correspondentes.
// Estado: FloatingController (quick actions) / shim Config (dock) / singleton NoLimits /
// instância local do WhatsAppOverlay / DockSettingsWindow (dock).
// Nota: a Dock em si deixou de ser instanciada aqui — virou painel nativo do core
// (ver docs/PORT-SPEC-DOCK.md); este entry só expõe o toggle de configuração.

import QtQuick
import Quickshell.Io
import qs.extras
import qs.components.misc
import "quickactions"
import "nolimits"
import "settings"
import "whatsapp"

Item {
    id: root

    QuickActions {}

    WhatsAppOverlay {
        id: whatsappOverlay
    }

    DockSettingsWindow {
        id: dockSettings

        visible: false
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

    function openDockSettings() {
        dockSettings.open();
    }

    function toggleDockSettings() {
        dockSettings.toggle();
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

        function openDockSettings(): void {
            root.openDockSettings();
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

    CustomShortcut {
        name: "docksettings"
        description: "Toggle dock settings window"
        onPressed: root.toggleDockSettings()
    }
}
