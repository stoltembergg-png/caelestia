// Portado de Serpantinum: src/quickshell/bar/modules/KodexBarWidget.qml (AGPL-3.0)
// Cápsula VERTICAL para a barra esquerda do Caelestia (~40px de largura):
// lista TODOS os provedores habilitados, cada um com seu ícone e o percentual da
// janela mais crítica ("worstPct"), empilhados. Badge de handoffs e ponto de
// offline discretos nos cantos. O popout abre por HOVER (Bar.checkPopout, mesmo
// padrão de tray/statusIcons); clique direito -> cicla o displayMode
// (alerts/worst/full). Clique esquerdo não alterna mais (evita conflito com o hover).
//
// Redesenho em relação ao port original (RowLayout horizontal, largo demais para
// a barra lateral e clipado) e ao primeiro redesign (que mostrava só 1 provedor):
// usa os mesmos tokens/estrutura dos itens nativos (StyledRect + radius full +
// Colours.tPalette.m3surfaceContainer + StateLayer + ColumnLayout), com
// implicitWidth = innerWidth e altura dinâmica pelo número de provedores.
// Sem âncora de barra (sem arquivo kodexbar_anchor.json).
//
// A seleção/percentual espelha o KodexBarWidget original; o visual foi reescrito
// com os tokens do Caelestia. Uso (patch opcional do core):
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

    // Injetado pela barra (DelegateChoice, patch do core). O popout nativo agora é
    // aberto por hover via Bar.checkPopout(); este binding permanece para casar com
    // o `bar: root` emitido pelo patch e para uso futuro do item.
    property var bar

    readonly property var providers: NoLimits.providers
    readonly property string displayMode: NoLimits.displayMode

    readonly property bool hasHandoffs: NoLimits.pendingHandoffs > 0
    readonly property bool serverDown: NoLimits.memoryEnabled && !NoLimits.serverUp

    // Porte alinhado aos ícones de status nativos: Power/StatusIcons usam
    // Tokens.font.icon.small (~20px de caixa, glifo ~15px). Cada provedor tem
    // uma linha; o logo fica num contêiner discreto comum (iconBox).
    readonly property real iconSize: Math.round(Tokens.sizes.bar.innerWidth * 0.375)
    readonly property real iconBox: Math.round(Tokens.sizes.bar.innerWidth * 0.5)
    readonly property real dotSize: Math.max(6, Math.round(iconSize * 0.3))

    // Lista realmente renderizada: todos os habilitados, ou um placeholder único
    // quando ainda não há dados (mantém o item estável durante loading/erro).
    readonly property var barProviders: visibleProviders()

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

    // Provedores habilitados; se não houver nenhum, devolve um item-sentinela
    // para exibir "…"/"ERR" sem quebrar o layout.
    function visibleProviders() {
        let list = enabledProviders();
        if (list.length === 0)
            return [{ provider: "", percentages: null, severity: "ok", error: false, placeholder: true }];
        return list;
    }

    // Percentual da janela mais crítica do provedor (sessão x semanal).
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

    function severityColor(sev) {
        if (sev === "critical")
            return Colours.palette.m3error;
        if (sev === "warning")
            return Colours.palette.m3tertiary;
        return Colours.palette.m3onSurfaceVariant;
    }

    function providerSeverity(p) {
        if (!p || p.placeholder)
            return "ok";
        return p.error ? "critical" : p.severity;
    }

    function providerColour(p) {
        return severityColor(providerSeverity(p));
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

    // Texto enxuto para a largura da barra. No modo "full" empilha sessão/semana
    // em duas linhas; nos demais, só o percentual da janela mais crítica.
    function providerText(p) {
        if (!p)
            return "";
        if (p.placeholder)
            return statusText();
        if (p.error)
            return "ERR";
        if (displayMode === "full") {
            let parts = [];
            if (p.percentages && typeof p.percentages.session === "number")
                parts.push("S " + Math.round(p.percentages.session) + "%");
            if (p.percentages && typeof p.percentages.weekly === "number")
                parts.push("W " + Math.round(p.percentages.weekly) + "%");
            if (parts.length > 0)
                return parts.join("\n");
        }
        let w = worstPct(p);
        return (w === null) ? "…" : (w + "%");
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
            // O hover abre/fecha o popout nativo (Bar.checkPopout); o clique
            // esquerdo não alterna mais para não conflitar com o hover.
            if (mouse.button === Qt.RightButton)
                root.cycleDisplayMode();
        }
    }

    ColumnLayout {
        id: content

        anchors.centerIn: parent
        // Folga horizontal para o texto percentual não encostar nas bordas da
        // cápsula; o label também reduz a fonte (abaixo) e usa HorizontalFit.
        width: Tokens.sizes.bar.innerWidth - Tokens.padding.medium
        spacing: Tokens.spacing.extraSmall

        Repeater {
            model: root.barProviders

            delegate: ProviderRow {}
        }
    }

    // Um provedor: ícone (logo do provedor ou fallback) sobre o percentual,
    // colorido pela severidade daquele provedor.
    component ProviderRow: ColumnLayout {
        id: providerRow

        required property var modelData
        required property int index

        readonly property string iconSource: root.providerIcon(providerRow.modelData ? providerRow.modelData.provider : "")
        readonly property bool hasIcon: providerRow.iconSource !== ""

        Layout.fillWidth: true
        Layout.alignment: Qt.AlignHCenter
        spacing: Tokens.spacing.extraSmall / 2

        // Contêiner comum aos logos: Codex é SVG transparente e OpenCode/Cursor
        // são PNGs com tile escuro; o fundo unifica a "família". Mantido discreto
        // (raio pequeno) para o item não pesar mais que os vizinhos nativos.
        StyledRect {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: root.iconBox
            implicitHeight: root.iconBox
            radius: Tokens.rounding.extraSmall
            color: Colours.tPalette.m3surfaceContainerHigh

            Image {
                anchors.centerIn: parent
                visible: providerRow.hasIcon
                source: providerRow.hasIcon ? providerRow.iconSource : ""
                sourceSize.width: root.iconSize
                sourceSize.height: root.iconSize
                width: root.iconSize
                height: root.iconSize
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            MaterialIcon {
                anchors.centerIn: parent
                visible: !providerRow.hasIcon
                text: "speed"
                color: root.providerColour(providerRow.modelData)
                fontStyle: Tokens.font.icon.small
            }
        }

        StyledText {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            visible: text !== ""
            text: root.providerText(providerRow.modelData)
            horizontalAlignment: Text.AlignHCenter
            fontSizeMode: Text.HorizontalFit
            minimumPixelSize: 7
            font: Tokens.font.label.builders.small.scale(0.85).build()
            color: root.providerColour(providerRow.modelData)
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
