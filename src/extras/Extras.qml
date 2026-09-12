// Portado de Serpantinum: src/quickshell/Shell.qml / Main.qml (AGPL-3.0)
// Entry do módulo extras: instancia os hosts QuickActions e NoLimits, os fallbacks
// standalone dos Ajustes da Dock e do WhatsApp e expõe o IPC target "extras" e os
// atalhos globais correspondentes.
// Estado: FloatingController (quick actions) / shim Config (dock) / singleton NoLimits /
// WhatsAppState (drawer nativo, via singleton) / DockSettingsWindow (dock) /
// WhatsAppSettingsWindow (whatsapp).
// Nota: a Dock e o WhatsApp deixaram de ser instanciados aqui — viraram painéis
// nativos do core (ver docs/PORT-SPEC-DOCK.md e docs/PORT-SPEC-WHATSAPP-V2.md);
// este entry só expõe os toggles de configuração.

import QtQuick
import Quickshell.Io
import qs.extras
import qs.components.misc
import "quickactions"
import "nolimits"
import "settings"

Item {
    id: root

    QuickActions {}

    DockSettingsWindow {
        id: dockSettings

        visible: false
    }

    WhatsAppSettingsWindow {
        id: whatsappSettings

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
        // O drawer nativo (L1) escuta os sinais do singleton WhatsAppState.
        if (WhatsAppState.visible)
            WhatsAppState.hideRequested();
        else
            WhatsAppState.showRequested();
    }

    function openDockSettings() {
        dockSettings.open();
    }

    function toggleDockSettings() {
        dockSettings.toggle();
    }

    function openWhatsAppSettings() {
        whatsappSettings.open();
    }

    function toggleWhatsAppSettings() {
        whatsappSettings.toggle();
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

        function toggleDockSettings(): void {
            root.toggleDockSettings();
        }

        function closeDockSettings(): void {
            dockSettings.close();
        }

        function openWhatsAppSettings(): void {
            root.openWhatsAppSettings();
        }

        function toggleWhatsAppSettings(): void {
            root.toggleWhatsAppSettings();
        }

        function closeWhatsAppSettings(): void {
            whatsappSettings.close();
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

    CustomShortcut {
        name: "whatsappsettings"
        description: "Toggle WhatsApp settings window"
        onPressed: root.toggleWhatsAppSettings()
    }
}
