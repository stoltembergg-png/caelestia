// Caelestia Extras — drawer nativo do WhatsApp (lane L1).
// Copyright (C) 2025 The Caelestia Extras contributors
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
// details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Painel NATIVO full-height à esquerda, no espírito da DockWrapper e da
// sidebar/Wrapper do core: SEM StyledWindow, SEM fundo próprio — o blob do core
// (ContentWindow: PanelBg/BlobGroup) desenha atrás. Aqui vivem só o conteúdo
// (WhatsAppPanel), a entrada/saída por `offsetScale` e o estado partilhado.
//
// Instanciado pelo patch do core (L2) em modules/drawers/Panels.qml:
//   ExtrasWhatsApp.Drawer {
//       id: whatsapp; screen: root.screen; screenState: root.screenState
//       anchors.top: parent.top; anchors.bottom: parent.bottom
//       anchors.left: parent.left
//   }
//
// API do contrato congelado (docs/PORT-SPEC-WHATSAPP-V2.md):
//   required property ShellScreen screen
//   property var screenState
//   property real offsetScale    // 0 = visível, 1 = oculto (animado)
//   function open() / close() / scheduleHide()
//   visible (Item.visible)       // offsetScale < 1
//   implicitWidth ~ min(560, screen.width*0.42)

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.extras as Extras

Item {
    id: root

    required property ShellScreen screen

    // Recebido pelo patch do core (Panels.qml). Mantido para uso/observação.
    property var screenState

    // ---- Config (extras.json -> "whatsapp") -----------------------------
    readonly property var defaultWaSettings: ({
            "openOnHover": true,
            "hoverDwell": 450,
            "hideDelay": 300,
            "minimalMode": "full",
            "hideSidebar": true,
            "hideTabs": true,
            "blur": true,
            "transparency": 85,
            "unloadOnClose": false,
            "fullscreenHide": true,
            "sidebarShortcut": "Ctrl+B"
        })

    property int configRevision: 0

    Connections {
        function onSettingsLoaded() {
            root.configRevision++;
        }

        function onDataReadyChanged() {
            root.configRevision++;
        }

        function onRawSettingsChanged() {
            root.configRevision++;
        }

        target: (typeof Extras !== "undefined" && Extras.Config) ? Extras.Config : null
    }

    // Merge tolerante dos defaults com o que existir em extras.json.
    readonly property var waSettings: {
        const rev = root.configRevision; // dependência reativa
        void rev;
        let incoming = null;
        if (typeof Extras !== "undefined" && Extras.Config) {
            if (Extras.Config.rawSettings && Extras.Config.rawSettings.whatsapp)
                incoming = Extras.Config.rawSettings.whatsapp;
            else if (typeof Extras.Config.getSetting === "function")
                incoming = Extras.Config.getSetting("whatsapp", root.defaultWaSettings);
        }
        const out = {};
        for (const k in root.defaultWaSettings)
            out[k] = root.defaultWaSettings[k];
        if (incoming && typeof incoming === "object") {
            for (const k in incoming)
                out[k] = incoming[k];
        }
        return out;
    }

    function cfgValue(key, fallback) {
        const s = root.waSettings;
        const v = (s && s[key] !== undefined) ? s[key] : undefined;
        return (v === undefined || v === null) ? fallback : v;
    }

    function cfgBool(key, fallback) {
        const v = root.cfgValue(key, fallback);
        if (typeof v === "boolean")
            return v;
        if (typeof v === "number")
            return v !== 0;
        if (typeof v === "string")
            return v.toLowerCase() === "true" || v === "1";
        return Boolean(v);
    }

    function cfgNum(key, fallback) {
        const v = root.cfgValue(key, fallback);
        const n = (typeof v === "number") ? v : parseFloat(v);
        return isNaN(n) ? fallback : n;
    }

    readonly property bool unloadOnClose: root.cfgBool("unloadOnClose", false)
    readonly property bool fullscreenHide: root.cfgBool("fullscreenHide", true)
    readonly property int hideDelay: Math.max(50, Math.round(root.cfgNum("hideDelay", 300)))

    // ---- Geometria / reveal ---------------------------------------------
    // 0 = totalmente visível, 1 = totalmente recolhido (o core usa em Regions).
    property real offsetScale: root._opened ? 0 : 1

    implicitWidth: Math.min(560, Math.round(root.screen.width * 0.42))
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    anchors.left: parent.left
    anchors.leftMargin: (-root.implicitWidth - 5) * root.offsetScale
    opacity: 1 - root.offsetScale
    visible: root.offsetScale < 1

    property bool _opened: false
    property bool _everOpened: false

    Behavior on offsetScale {
        Anim {
            type: Anim.DefaultSpatial
        }
    }

    function open() {
        root._everOpened = true;
        root._opened = true;
    }

    function close() {
        root._opened = false;
        hideTimer.stop();
    }

    function scheduleHide() {
        if (root._opened)
            hideTimer.restart();
    }

    Timer {
        id: hideTimer

        interval: root.hideDelay
        repeat: false
        onTriggered: root.close()
    }

    // ---- Foco / estado partilhado ---------------------------------------
    readonly property bool focused: {
        const mon = Hypr.focusedMonitor;
        return !mon || mon.name === root.screen.name;
    }

    Connections {
        function onShowRequested() {
            if (root.focused)
                root.open();
        }

        function onHideRequested() {
            if (root.focused)
                root.close();
        }

        target: (typeof Extras !== "undefined" && Extras.WhatsAppState) ? Extras.WhatsAppState : null
    }

    // Fullscreen: o sensor do core (L2) também fecha; aqui garantimos o mesmo
    // para o atalho/IPC e respeitamos `fullscreenHide`.
    readonly property bool fullscreen: {
        try {
            const fs = Hypr.activeToplevel?.lastIpcObject?.fullscreen;
            return fs !== undefined && fs !== null && fs > 1;
        } catch (e) {
            return false;
        }
    }

    onFullscreenChanged: {
        if (root.fullscreen && root.fullscreenHide)
            root.close();
    }

    function publishState() {
        const state = (typeof Extras !== "undefined" && Extras.WhatsAppState) ? Extras.WhatsAppState : null;
        if (state)
            state.visible = root.visible;
    }

    onVisibleChanged: {
        if (root.visible)
            root._everOpened = true;
        root.publishState();
    }
    onOffsetScaleChanged: root.publishState()
    Component.onCompleted: root.publishState()

    Shortcut {
        sequence: "Escape"
        enabled: root.visible
        onActivated: root.close()
    }

    // ---- Conteúdo (LAZY) ------------------------------------------------
    // Só instancia o WebEngine depois da primeira abertura. Mantém vivo durante
    // a animação de fecho para a superfície não "piscar"; `unloadOnClose` decide
    // se liberta a view quando fica totalmente oculta (o login persiste no perfil).
    Loader {
        id: contentLoader

        anchors.fill: parent

        active: root._everOpened && (root.visible || root.offsetScale < 1 || !root.unloadOnClose)

        sourceComponent: WhatsAppPanel {
            shown: root.visible
            settings: root.waSettings
            profile: Extras.WhatsAppProfile.profile

            onCloseRequested: root.close()
        }
    }
}
