// Portado de Serpantinum: src/quickshell/bar/modules/KodexBarWidget.qml (AGPL-3.0)
// Cápsula VERTICAL para a barra esquerda do Caelestia (~40px de largura):
// ícone do provedor de pior severidade + percentual, com badge de handoffs e
// ponto de offline discretos nos cantos. Clique esquerdo -> NoLimits.toggle();
// clique direito -> cicla o displayMode (alerts/worst/full).
//
// Redesenho em relação ao port original (que era um RowLayout horizontal, largo
// demais para a barra lateral e clipado): agora usa os mesmos tokens/estrutura
// dos itens nativos (StyledRect + radius full + Colours.tPalette.m3surfaceContainer
// + StateLayer + ColumnLayout centralizado), com implicitWidth = innerWidth e
// altura pelo conteúdo. Sem âncora de barra (sem arquivo kodexbar_anchor.json).
//
// A lógica de seleção/percentual espelha o KodexBarWidget original; o visual foi
// reescrito com os tokens do Caelestia. Uso (patch opcional do core):
//   DelegateChoice { roleValue: "kodexbar"; NoLimitsBarItem {} }

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.extras

StyledRect {
    id: root

    readonly property var providers: NoLimits.providers
    readonly property string displayMode: NoLimits.displayMode

    readonly property bool hasHandoffs: NoLimits.pendingHandoffs > 0
    readonly property bool serverDown: NoLimits.memoryEnabled && !NoLimits.serverUp

    // Mesma escala dos ícones de status nativos (icon.medium ~24px) dentro dos
    // ~40px internos da barra.
    readonly property real iconSize: Math.round(Tokens.sizes.bar.innerWidth * 0.55)
    readonly property real dotSize: Math.max(6, Math.round(iconSize * 0.3))

    // Provedor exibido (pior percentual entre os habilitados) e sua apresentação.
    // Propriedades derivadas evitam recalcular/duplicar a seleção nos bindings.
    readonly property var displayProvider: worstProvider()
    readonly property string displayIcon: displayProvider !== null ? providerIcon(displayProvider.provider) : ""
    readonly property bool hasProviderIcon: displayProvider !== null && displayIcon !== ""
    readonly property string displaySeverity: displayProvider !== null ? (displayProvider.error ? "critical" : displayProvider.severity) : worstSeverity()
    readonly property color displayColour: severityColor(displaySeverity)

    function isDisabled(id) {
        return NoLimits.isDisabled(id);
    }

    function enabledProviders() {
        let out = [];
        for (let i = 0; i < providers.length; i++) {
            if (!isDisabled(providers[i].provider))
                out.push(providers[i]);
        }
        return out;
    }

    function shownProviders() {
        let list = enabledProviders();
        if (displayMode !== "alerts")
            return list;
        let alerts = [];
        for (let i = 0; i < list.length; i++) {
            let p = list[i];
            if (p.error || p.severity === "warning" || p.severity === "critical")
                alerts.push(p);
        }
        return alerts;
    }

    function worstPct(p) {
        let vals = [];
        if (p && p.percentages) {
            if (typeof p.percentages.session === "number")
                vals.push(p.percentages.session);
            if (typeof p.percentages.weekly === "number")
                vals.push(p.percentages.weekly);
        }
        if (vals.length === 0)
            return null;
        let worst = vals[0];
        for (let i = 1; i < vals.length; i++) {
            if (vals[i] > worst)
                worst = vals[i];
        }
        return Math.round(worst);
    }

    function severityRank(sev) {
        if (sev === "critical")
            return 2;
        if (sev === "warning")
            return 1;
        return 0;
    }

    function worstSeverity() {
        let list = enabledProviders();
        let worst = "ok";
        for (let i = 0; i < list.length; i++) {
            let s = list[i].error ? "critical" : list[i].severity;
            if (severityRank(s) > severityRank(worst))
                worst = s;
        }
        if (displayMode === "alerts" && list.length === 0)
            worst = "ok";
        return worst;
    }

    function severityColor(sev) {
        if (sev === "critical")
            return Colours.palette.m3error;
        if (sev === "warning")
            return Colours.palette.m3tertiary;
        return Colours.palette.m3onSurfaceVariant;
    }

    // Provedor de pior percentual entre os exibidos (define ícone e número).
    function worstProvider() {
        let list = shownProviders();
        let best = null;
        let bestPct = -1;
        for (let i = 0; i < list.length; i++) {
            let p = list[i];
            let w = (p.error ? 100 : (worstPct(p) === null ? 0 : worstPct(p)));
            if (w > bestPct) {
                bestPct = w;
                best = p;
            }
        }
        return best;
    }

    function providerId(p) {
        return String(p || "").toLowerCase();
    }

    function providerIcon(id) {
        let p = providerId(id);
        let home = (typeof Quickshell !== "undefined" && Quickshell.env) ? Quickshell.env("HOME") : "";
        if (p === "codex")
            return "file://" + home + "/.local/share/icons/hicolor/scalable/apps/codex.svg";
        if (p === "opencodego")
            return "file://" + home + "/.local/share/icons/hicolor/512x512/apps/ai.opencode.desktop.png";
        if (p === "cursor")
            return "file://" + home + "/.local/share/icons/hicolor/32x32/apps/co.anysphere.cursor.png";
        return "";
    }

    function statusText() {
        if (NoLimits.quotaLoading && providers.length === 0)
            return "…";
        if (NoLimits.quotaError && providers.length === 0)
            return "ERR";
        return "";
    }

    // Texto enxuto para a largura estreita da barra: no modo "full" empilha as
    // janelas de sessão/semana em duas linhas em vez de uma linha larga.
    function barText() {
        if (NoLimits.quotaLoading && providers.length === 0)
            return "…";
        if (NoLimits.quotaError && providers.length === 0)
            return "ERR";
        let p = displayProvider;
        if (!p)
            return "";
        if (p.error)
            return "ERR";
        if (displayMode === "full") {
            let parts = [];
            if (p.percentages && typeof p.percentages.session === "number")
                parts.push("S " + Math.round(p.percentages.session) + "%");
            if (p.percentages && typeof p.percentages.weekly === "number")
                parts.push("W " + Math.round(p.percentages.weekly) + "%");
            return parts.join("\n");
        }
        let w = worstPct(p);
        return (w === null) ? "" : (w + "%");
    }

    function cycleDisplayMode() {
        let order = ["alerts", "worst", "full"];
        let idx = order.indexOf(displayMode);
        NoLimits.setDisplayMode(order[(idx + 1) % order.length]);
    }

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: content.implicitHeight + Tokens.padding.small * 2
    radius: Tokens.rounding.full
    color: Colours.tPalette.m3surfaceContainer

    Behavior on implicitHeight {
        Anim {}
    }

    StateLayer {
        anchors.fill: parent
        radius: Tokens.rounding.full
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        onClicked: mouse => {
            if (mouse.button === Qt.RightButton)
                root.cycleDisplayMode();
            else
                NoLimits.toggle();
        }
    }

    ColumnLayout {
        id: content

        anchors.centerIn: parent
        // Folga horizontal para o texto percentual não encostar nas bordas da
        // cápsula; o label usa HorizontalFit para encolher só quando necessário.
        width: Tokens.sizes.bar.innerWidth - Tokens.padding.small
        spacing: Tokens.spacing.extraSmall

        Image {
            Layout.alignment: Qt.AlignHCenter
            visible: root.hasProviderIcon
            source: root.hasProviderIcon ? root.displayIcon : ""
            sourceSize.width: root.iconSize
            sourceSize.height: root.iconSize
            Layout.preferredWidth: root.iconSize
            Layout.preferredHeight: root.iconSize
            fillMode: Image.PreserveAspectFit
            smooth: true
        }

        MaterialIcon {
            Layout.alignment: Qt.AlignHCenter
            visible: !root.hasProviderIcon
            text: "speed"
            color: root.displayColour
            fontStyle: Tokens.font.icon.medium
        }

        StyledText {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            visible: root.barText() !== ""
            text: root.barText()
            horizontalAlignment: Text.AlignHCenter
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 9
            font: Tokens.font.label.small
            color: root.displayColour
        }
    }

    // Badge discreto de handoffs pendentes (canto superior direito).
    StyledRect {
        id: handoffBadge

        visible: root.hasHandoffs
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: Tokens.padding.extraSmall / 2
        anchors.rightMargin: Tokens.padding.extraSmall / 2
        implicitWidth: Math.max(handoffText.implicitHeight + Tokens.padding.extraSmall, handoffText.implicitWidth + Tokens.padding.extraSmall / 2)
        implicitHeight: handoffText.implicitHeight + Tokens.padding.extraSmall / 2
        radius: height / 2
        color: Colours.palette.m3tertiary

        StyledText {
            id: handoffText

            anchors.centerIn: parent
            text: "" + NoLimits.pendingHandoffs
            font: Tokens.font.label.builders.small.scale(0.72).build()
            color: Colours.palette.m3onTertiary
        }
    }

    // Ponto discreto de servidor de memória offline (canto inferior direito).
    StyledRect {
        visible: root.serverDown
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        anchors.bottomMargin: Tokens.padding.extraSmall
        anchors.rightMargin: Tokens.padding.extraSmall
        implicitWidth: root.dotSize
        implicitHeight: root.dotSize
        radius: width / 2
        color: Colours.palette.m3error
    }
}
