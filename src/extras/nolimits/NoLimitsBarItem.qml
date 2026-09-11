// Portado de Serpantinum: src/quickshell/bar/modules/KodexBarWidget.qml (AGPL-3.0)
// Cápsula compacta para a barra do Caelestia: ícone + %/severidade + badge de
// handoffs + ponto offline. Clique esquerdo -> NoLimits.toggle(); clique direito
// -> cicla o displayMode (alerts/worst/full). Visual nativo (Colours/Tokens/
// StateLayer), sem âncora de barra (sem arquivo kodexbar_anchor.json).
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

Item {
    id: root

    readonly property var providers: NoLimits.providers
    readonly property string displayMode: NoLimits.displayMode

    readonly property bool hasHandoffs: NoLimits.pendingHandoffs > 0
    readonly property bool serverDown: NoLimits.memoryEnabled && !NoLimits.serverUp

    readonly property real iconSize: Math.round(Tokens.sizes.bar.innerWidth * 0.42)

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

    // Provider de pior percentual entre os exibidos (define ícone e número).
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

    function pctText() {
        let p = worstProvider();
        if (!p)
            return statusText();
        if (p.error)
            return "ERR";
        if (displayMode === "full") {
            let parts = [];
            if (p.percentages && p.percentages.session !== null && p.percentages.session !== undefined)
                parts.push("S " + Math.round(p.percentages.session) + "%");
            if (p.percentages && p.percentages.weekly !== null && p.percentages.weekly !== undefined)
                parts.push("W " + Math.round(p.percentages.weekly) + "%");
            return parts.join(" ");
        }
        let w = worstPct(p);
        return (w === null) ? "" : (w + "%");
    }

    function cycleDisplayMode() {
        let order = ["alerts", "worst", "full"];
        let idx = order.indexOf(displayMode);
        NoLimits.setDisplayMode(order[(idx + 1) % order.length]);
    }

    implicitWidth: row.implicitWidth + Tokens.padding.large
    implicitHeight: Tokens.sizes.bar.innerWidth

    StyledRect {
        anchors.fill: parent
        radius: Tokens.rounding.full
        color: Colours.tPalette.m3surfaceContainer
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

    RowLayout {
        id: row

        anchors.centerIn: parent
        spacing: Tokens.spacing.small

        Image {
            Layout.alignment: Qt.AlignVCenter
            visible: root.worstProvider() !== null && root.providerIcon(root.worstProvider().provider) !== ""
            source: root.worstProvider() !== null ? root.providerIcon(root.worstProvider().provider) : ""
            sourceSize.width: root.iconSize
            sourceSize.height: root.iconSize
            Layout.preferredWidth: root.iconSize
            Layout.preferredHeight: root.iconSize
            fillMode: Image.PreserveAspectFit
            smooth: true
        }

        MaterialIcon {
            Layout.alignment: Qt.AlignVCenter
            visible: !(root.worstProvider() !== null && root.providerIcon(root.worstProvider().provider) !== "")
            text: "speed"
            color: root.severityColor(root.worstSeverity())
        }

        StyledRect {
            Layout.alignment: Qt.AlignVCenter
            visible: root.pctText() !== ""
            implicitWidth: pctLabel.implicitWidth + Tokens.padding.small
            implicitHeight: pctLabel.implicitHeight + Tokens.padding.extraSmall
            radius: height / 2
            color: Qt.alpha(root.severityColor(root.worstSeverity()), 0.16)

            StyledText {
                id: pctLabel

                anchors.centerIn: parent
                text: root.pctText()
                font: Tokens.font.label.small
                color: root.severityColor(root.worstSeverity())
            }
        }

        StyledRect {
            Layout.alignment: Qt.AlignVCenter
            visible: root.hasHandoffs
            implicitWidth: handoffLabel.implicitWidth + Tokens.padding.small
            implicitHeight: handoffLabel.implicitHeight + Tokens.padding.extraSmall
            radius: height / 2
            color: Qt.alpha(Colours.palette.m3tertiary, 0.22)

            StyledText {
                id: handoffLabel

                anchors.centerIn: parent
                text: "" + NoLimits.pendingHandoffs
                font: Tokens.font.label.small
                color: Colours.palette.m3tertiary
            }
        }

        StyledRect {
            Layout.alignment: Qt.AlignVCenter
            visible: root.serverDown
            implicitWidth: Math.round(root.iconSize * 0.42)
            implicitHeight: implicitWidth
            radius: width / 2
            color: Colours.palette.m3error
        }
    }
}
