// Portado de Serpantinum: src/quickshell/dock/Dock.qml (AGPL-3.0)
// Port para Caelestia (L1): painel NATIVO. Sem StyledWindow / janela de exclusão /
// fundo próprio — o blob do core (ContentWindow: PanelBg/BlobGroup) desenha atrás
// e o aro é desenhado por BlobInvertedRect. Aqui só vivemos o conteúdo (DockPanel),
// a lógica de entrada/saída (offsetScale), o sensor de borda e o espaço reservado.
//
// Instanciado pelo patch do core em modules/drawers/Panels.qml:
//   ExtrasDock.Wrapper {
//       id: dock; screen: root.screen; screenState: root.screenState
//       anchors.horizontalCenter: parent.horizontalCenter
//       anchors.bottom: parent.bottom
//   }
//
// API do contrato congelado (docs/PORT-SPEC-DOCK.md):
//   required property ShellScreen screen
//   property real offsetScale      // 0 = visível, 1 = oculto (animado)
//   property real sensorHeight     // faixa de hover p/ autohide (default 6)
//   implicitWidth / implicitHeight

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

    // Recebido pelo patch do core (Panels.qml). Mantido para futuro uso/observação.
    property var screenState

    // ---- API / geometria ------------------------------------------------
    // 0 = totalmente visível, 1 = totalmente recolhida (o core usa em Regions).
    property real offsetScale: root.targetOffsetScale
    // Faixa de hover no rodapé quando auto-oculta.
    property real sensorHeight: root.cfgNum("sensorHeight", 6)

    implicitWidth: panel.implicitWidth
    implicitHeight: panel.implicitHeight

    // ---- Config (extras.json -> "dock") ---------------------------------
    readonly property var defaultDockSettings: ({
            "enabled": true,
            "position": "bottom",
            "elementSize": 44,
            "floating": false,
            "opacity": 100,
            "exclusive": true,
            "alwaysVisible": true,
            "showOnFullscreen": false,
            "autohide": false,
            "autohideTimeout": 1000,
            "animations": true,
            "cascadeScale": true,
            "hoverScale": 120,
            "sensorHeight": 6,
            "editing": false,
            "apps": []
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
    readonly property var dockSettings: {
        const rev = root.configRevision; // dependência reativa
        void rev;
        let incoming = null;
        if (typeof Extras !== "undefined" && Extras.Config) {
            if (Extras.Config.rawSettings && Extras.Config.rawSettings.dock)
                incoming = Extras.Config.rawSettings.dock;
            else if (typeof Extras.Config.getSetting === "function")
                incoming = Extras.Config.getSetting("dock", root.defaultDockSettings);
        }
        const out = {};
        for (const k in root.defaultDockSettings)
            out[k] = root.defaultDockSettings[k];
        if (incoming && typeof incoming === "object") {
            for (const k in incoming)
                out[k] = incoming[k];
        }
        return out;
    }

    function cfgValue(key, fallback) {
        const s = root.dockSettings;
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

    readonly property bool dockEnabled: root.cfgBool("enabled", true)
    readonly property bool alwaysVisible: root.cfgBool("alwaysVisible", true)
    readonly property bool showOnFullscreen: root.cfgBool("showOnFullscreen", false)
    readonly property bool exclusive: root.cfgBool("exclusive", true)
    readonly property bool autohide: root.cfgBool("autohide", false)
    readonly property int autohideTimeout: Math.max(50, Math.round(root.cfgNum("autohideTimeout", 1000)))
    readonly property bool animations: root.cfgBool("animations", true)
    readonly property bool cascadeScale: root.cfgBool("cascadeScale", true)
    readonly property real elementSize: Math.max(16, root.cfgNum("elementSize", 44))
    readonly property real hoverScale: {
        const n = root.cfgNum("hoverScale", 120);
        return n < 100 ? 1.2 : n / 100.0;
    }

    // ---- Fullscreen -----------------------------------------------------
    // O core não expõe gerenciador de toplevels; usamos o serviço Hypr.
    readonly property bool fullscreen: {
        try {
            const fs = Hypr.activeToplevel?.lastIpcObject?.fullscreen;
            return fs !== undefined && fs !== null && fs > 1;
        } catch (e) {
            return false;
        }
    }

    // ---- Reveal / autohide ---------------------------------------------
    property bool sensorHovered: false

    Timer {
        id: autohideTimer

        interval: root.autohideTimeout
        repeat: false
    }

    function updateAutohideTimer() {
        if (panel.editMode || root.sensorHovered || panel.hovered) {
            autohideTimer.stop();
        } else if (root.autohide && root.shown) {
            autohideTimer.restart();
        } else {
            autohideTimer.stop();
        }
    }

    readonly property bool revealed: !root.autohide || panel.editMode || root.sensorHovered || panel.hovered || autohideTimer.running

    onSensorHoveredChanged: root.updateAutohideTimer()

    // ---- Visibilidade ---------------------------------------------------
    readonly property bool active: root.dockEnabled && (root.alwaysVisible || panel.hasApps || panel.editMode)
    readonly property bool hiddenByFullscreen: root.fullscreen && !root.showOnFullscreen
    // "shown" evita sobrepor o membro final Item.visible.
    readonly property bool shown: root.active && !root.hiddenByFullscreen
    readonly property real targetOffsetScale: (!root.shown || (root.autohide && !root.revealed)) ? 1 : 0

    Behavior on offsetScale {
        enabled: root.animations

        Anim {
            type: Anim.DefaultSpatial
        }
    }

    // Deslocamento para o blob afundar no aro: move o painel para fora da tela.
    readonly property real hideGap: Math.max(root.sensorHeight, Math.round(Config.border.thickness))
    readonly property real hideShift: (root.implicitHeight + root.hideGap) * root.offsetScale

    // Sink no aro inferior. O `Panels` do core tem bottomMargin = borderThickness e
    // o `PanelBg` posiciona o blob em `panel.y + borderThickness`, então a base do
    // painel parava ~borderThickness (10px) acima da borda real, deixando os cantos
    // inferiores arredondados "soltos" (pill flutuante). Descer a base por essa
    // espessura faz a superfície tocar o rodapé do ecrã, sobrepõe o aro e o
    // smoothing (Config.border.smoothing) funde os dois; o cornerFill do core
    // enterra os cantos inferiores sobre a borda (deixa de haver pill solta).
    // Sem aro em fullscreen (borderThickness = 0), não há o que afundar.
    readonly property real aroSink: root.fullscreen ? 0 : Math.round(Config.border.thickness)

    anchors.bottomMargin: -root.hideShift - root.aroSink

    // ---- Publica estado para o core (Exclusions) ------------------------
    function publishState() {
        const state = (typeof Extras !== "undefined" && Extras.DockState) ? Extras.DockState : null;
        if (!state)
            return;
        state.fullscreenActive = root.fullscreen;
        state.visible = root.shown;
        state.reservedSpace = (root.exclusive && !root.autohide && root.shown && !root.fullscreen) ? Math.round(root.implicitHeight) : 0;
    }

    onOffsetScaleChanged: root.publishState()
    onFullscreenChanged: root.publishState()
    onShownChanged: {
        root.updateAutohideTimer();
        root.publishState();
    }
    onExclusiveChanged: root.publishState()
    onAutohideChanged: {
        root.updateAutohideTimer();
        root.publishState();
    }
    Component.onCompleted: root.publishState()

    // ---- Conteúdo -------------------------------------------------------
    DockPanel {
        id: panel

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom

        settings: root.dockSettings
        animations: root.animations
        elementSize: root.elementSize
        hoverScale: root.hoverScale
        cascadeScale: root.cascadeScale
        panelOpacity: root.cfgNum("opacity", 100) / 100.0

        onHoveredChanged: root.updateAutohideTimer()
        onEditModeChanged: root.updateAutohideTimer()
    }

    // Sensor de borda: fica colado ao rodapé mesmo com a dock recolhida.
    // Compensa o deslocamento (hideShift) para permanecer no ecrã.
    Item {
        id: sensor

        visible: root.autohide && !root.hiddenByFullscreen
        enabled: visible
        width: root.width
        height: root.sensorHeight
        // A dock deslocada para baixo por hideShift; compensa para o sensor
        // continuar colado ao rodapé do ecrã (coordenadas do pai).
        y: root.implicitHeight - root.hideShift - root.sensorHeight
        z: -1

        HoverHandler {
            id: sensorHover

            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onHoveredChanged: root.sensorHovered = hovered
        }
    }
}
