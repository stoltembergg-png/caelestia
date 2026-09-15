// Portado de Serpantinum: src/quickshell/Shell.qml / Main.qml (AGPL-3.0)
// Entry do módulo extras: instancia o host QuickActions e o singleton NoLimits,
// o fallback dos Ajustes da Dock e expõe o IPC target "extras" e os atalhos globais.
// Estado: FloatingController (quick actions) / shim Config (dock) / singleton NoLimits.
// Nota: a Dock é painel nativo do core (ver docs/PORT-SPEC-DOCK.md); o WhatsApp WebView
// foi REMOVIDO (a integração nativa vive no repo caelestia-whatsapp).

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

        function openDockSettings(): void {
            root.openDockSettings();
        }

        function toggleDockSettings(): void {
            root.toggleDockSettings();
        }

        function closeDockSettings(): void {
            dockSettings.close();
        }

    }

    CustomShortcut {
        name: "quickactions"
        description: I18n.t("shortcuts.quickactions")
        onPressed: root.toggleQuickActions()
    }

    CustomShortcut {
        name: "dock"
        description: I18n.t("shortcuts.dock")
        onPressed: root.toggleDock()
    }

    CustomShortcut {
        name: "nolimits"
        description: I18n.t("shortcuts.nolimits")
        onPressed: root.toggleNoLimits()
    }

    CustomShortcut {
        name: "docksettings"
        description: I18n.t("shortcuts.docksettings")
        onPressed: root.toggleDockSettings()
    }

}
