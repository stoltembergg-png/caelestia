// Portado de Serpantinum: src/quickshell/kodexbar/KodexBarPopup.qml (AGPL-3.0)
// Port 1:1 da UI (4 abas: Limits/Memory/Activity/Settings). Adaptações de port:
//  - imports relativos do Serpantinum -> shims qs.extras / qs.extras.reusables;
//  - sem dependência da janela da barra/IPC: o host (NoLimitsOverlay) controla a
//    visibilidade e lê NoLimits.visible / NoLimits.showRequested.

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.extras
import qs.extras.reusables

Item {
    id: window
    focus: true

    function s(val) {
        return Scaler.s(val);
    }

    property real introMain: 1
    property string activeView: "limits"

    readonly property string displayMode: NoLimits.displayMode
    readonly property var disabledList: NoLimits.disabledList

    function isDisabled(id) {
        return NoLimits.isDisabled(id);
    }

    function toggleProvider(id) {
        NoLimits.toggleProvider(id);
    }

    function setDisplayMode(mode) {
        NoLimits.setDisplayMode(mode);
    }

    function resetAndPlayIntro() {
        introMain = 0;
        introAnim.restart();
    }

    function refresh() {
        NoLimits.refresh();
    }

    function severityColor(sev) {
        if (sev === "critical") {
            let f = 0.4;
            return Qt.rgba(
                ThemeBackend.red.r * (1 - f) + ThemeBackend.mauve.r * f,
                ThemeBackend.red.g * (1 - f) + ThemeBackend.mauve.g * f,
                ThemeBackend.red.b * (1 - f) + ThemeBackend.mauve.b * f,
                1);
        }
        if (sev === "warning") return ThemeBackend.peach;
        return ThemeBackend.mauve;
    }

    function providerId(p) {
        return String(p || "").toLowerCase();
    }

    function providerName(id) {
        let p = providerId(id);
        if (p === "codex") return "Codex";
        if (p === "claude") return "Claude";
        if (p === "grok") return "Grok";
        if (p === "antigravity") return "Antigravity";
        if (p === "opencodego") return "OpenCode Go";
        if (p === "cursor") return "Cursor";
        return id;
    }

    function providerBadge(id) {
        let p = providerId(id);
        if (p === "codex") return "Cx";
        if (p === "claude") return "Cl";
        if (p === "grok") return "Gk";
        if (p === "antigravity") return "Ag";
        if (p === "opencodego") return "op";
        if (p === "cursor") return "cu";
        return p.substring(0, 2);
    }

    function providerIcon(id) {
        let p = providerId(id);
        let home = (typeof Quickshell !== "undefined" && Quickshell.env) ? Quickshell.env("HOME") : "";
        if (p === "codex") return "file://" + home + "/.local/share/icons/hicolor/scalable/apps/codex.svg";
        if (p === "opencodego") return "file://" + home + "/.local/share/icons/hicolor/512x512/apps/ai.opencode.desktop.png";
        if (p === "cursor") return "file://" + home + "/.local/share/icons/hicolor/32x32/apps/co.anysphere.cursor.png";
        return "";
    }

    readonly property bool darkBase: (0.299 * ThemeBackend.base.r + 0.587 * ThemeBackend.base.g + 0.114 * ThemeBackend.base.b) < 0.5
    readonly property color frameLine: darkBase ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(0, 0, 0, 0.14)
    readonly property color cardLine: darkBase ? Qt.rgba(1, 1, 1, 0.055) : Qt.rgba(0, 0, 0, 0.07)
    readonly property color chipFill: ThemeBackend.surface1

    function aggregateSeverity() {
        let rank = { ok: 0, warning: 1, critical: 2 };
        let worst = "ok";
        let countAlerts = 0;
        for (let i = 0; i < NoLimits.cards.length; i++) {
            let e = NoLimits.cards[i].entry;
            if (NoLimits.isDisabled(e.provider)) continue;
            let sev = NoLimits.providerSeverity(e);
            if (sev !== "ok") countAlerts++;
            if (rank[sev] > rank[worst]) worst = sev;
        }
        return { severity: worst, alerts: countAlerts };
    }

    function fmtReset(iso) {
        if (!iso) return "";
        let d = new Date(iso);
        if (isNaN(d.getTime())) return "";
        let diff = d.getTime() - window.resetClock;
        if (diff <= 0) return "agora";
        let totalMinutes = Math.max(1, Math.ceil(diff / 60000));
        if (totalMinutes < 60) return totalMinutes + "min";
        let totalHours = Math.floor(totalMinutes / 60);
        if (totalHours < 24) return totalHours + "h";
        let days = Math.floor(totalHours / 24);
        let hours = totalHours % 24;
        return days + "d" + (hours > 0 ? " " + hours + "h" : "");
    }

    property double resetClock: Date.now()

    Timer {
        id: resetClockTimer
        interval: 30000
        repeat: true
        running: window.visible
        onTriggered: window.resetClock = Date.now()
    }

    Timer {
        id: focusTimer
        interval: 60
        repeat: false
        onTriggered: window.forceActiveFocus()
    }

    readonly property var viewIds: ["limits", "memory", "activity", "settings"]
    readonly property int viewIndex: Math.max(0, viewIds.indexOf(activeView))
    property int pendingViewIndex: -1

    function switchView(id) {
        let idx = viewIds.indexOf(id);
        if (idx === -1) idx = 0;
        if (idx === viewIndex) return;
        pendingViewIndex = idx;
        viewAnim.restart();
    }

    function gotoTab(tab) {
        switchView(tab);
    }

    function applyRequestedView() {
        if (NoLimits.requestedView !== "") {
            switchView(NoLimits.requestedView);
            NoLimits.requestedView = "";
        }
    }

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus();
            focusTimer.restart();
            resetClock = Date.now();
            resetAndPlayIntro();
            applyRequestedView();
            refresh();
        }
    }

    Connections {
        target: NoLimits
        function onRequestedViewChanged() {
            applyRequestedView();
        }
    }

    SequentialAnimation {
        id: viewAnim
        NumberAnimation { target: viewStack; property: "opacity"; to: 0; duration: 80; easing.type: Easing.InQuad }
        ScriptAction {
            script: {
                let dir = (window.pendingViewIndex > window.viewIndex) ? 1 : -1;
                viewShift.x = dir * window.s(14);
                window.activeView = window.viewIds[window.pendingViewIndex];
            }
        }
        ParallelAnimation {
            NumberAnimation { target: viewStack; property: "opacity"; to: 1; duration: 170; easing.type: Easing.OutQuad }
            NumberAnimation { target: viewShift; property: "x"; to: 0; duration: 190; easing.type: Easing.OutCubic }
        }
    }

    ParallelAnimation {
        id: introAnim
        running: false
        NumberAnimation { target: window; property: "introMain"; from: 0; to: 1.0; duration: 800; easing.type: Easing.OutExpo }
    }

    Component.onCompleted: {
        refresh();
    }

    Item {
        anchors.fill: parent
        scale: 0.95 + (0.05 * introMain)
        opacity: introMain
        transform: Translate { y: window.s(20) * (1 - introMain) }

        Rectangle {
            id: frame
            anchors.fill: parent
            radius: ThemeBackend.borderRadius
            color: ThemeBackend.base
            border.width: 0
            clip: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.s(16)
                spacing: window.s(12)

                RowLayout {
                    Layout.fillWidth: true
                    spacing: window.s(8)

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        width: window.s(8)
                        height: width
                        radius: width / 2
                        color: window.activeView === "memory"
                            ? (NoLimits.serverUp ? ThemeBackend.green : ThemeBackend.red)
                            : window.severityColor(window.aggregateSeverity().severity)
                    }

                    Text {
                        Layout.alignment: Qt.AlignVCenter
                        text: "No Limits"
                        font.family: ThemeBackend.fontFamily
                        font.weight: Font.Bold
                        font.pixelSize: window.s(14)
                        color: ThemeBackend.text
                    }

                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter
                        visible: window.activeView === "limits" && window.aggregateSeverity().alerts > 0
                        radius: height / 2
                        color: window.chipFill
                        border.width: 0
                        implicitWidth: alertsText.implicitWidth + window.s(14)
                        implicitHeight: window.s(18)

                        Text {
                            id: alertsText
                            anchors.centerIn: parent
                            text: window.aggregateSeverity().alerts + " em alerta"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: window.s(9)
                            color: ThemeBackend.subtext0
                        }
                    }

                    Item { Layout.fillWidth: true }

                    IconButton {
                        Layout.preferredWidth: window.s(26)
                        Layout.preferredHeight: window.s(26)
                        Layout.alignment: Qt.AlignVCenter
                        visible: NoLimits.serverUp
                        cornerRadius: Math.max(0, ThemeBackend.borderRadius - window.s(3))
                        buttonIcon: "󰖟"
                        iconFontSize: window.s(12)
                        accentColor: Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.6)
                        textColor: isHoveredOrHighlighted ? ThemeBackend.text : ThemeBackend.overlay1
                        onClicked: NoLimits.openWebUi()
                    }

                    IconButton {
                        Layout.preferredWidth: window.s(26)
                        Layout.preferredHeight: window.s(26)
                        Layout.alignment: Qt.AlignVCenter
                        cornerRadius: Math.max(0, ThemeBackend.borderRadius - window.s(3))
                        buttonIcon: "󰒓"
                        iconFontSize: window.s(12)
                        accentColor: window.activeView === "settings"
                            ? Qt.rgba(ThemeBackend.surface2.r, ThemeBackend.surface2.g, ThemeBackend.surface2.b, 0.9)
                            : Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.6)
                        textColor: isHoveredOrHighlighted ? ThemeBackend.text : ThemeBackend.overlay1
                        onClicked: window.switchView(window.activeView === "settings" ? "limits" : "settings")
                    }

                    IconButton {
                        Layout.preferredWidth: window.s(26)
                        Layout.preferredHeight: window.s(26)
                        Layout.alignment: Qt.AlignVCenter
                        cornerRadius: Math.max(0, ThemeBackend.borderRadius - window.s(3))
                        buttonIcon: "󰑐"
                        iconFontSize: window.s(12)
                        iconOffsetX: window.s(1)
                        accentColor: Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.6)
                        textColor: isHoveredOrHighlighted ? ThemeBackend.text : ThemeBackend.overlay1
                        onClicked: window.refresh()
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: window.s(6)

                    Repeater {
                        model: [
                            { id: "limits", label: I18n.t("kodexbar.limits") },
                            { id: "memory", label: I18n.t("kodexbar.memory") },
                            { id: "activity", label: I18n.t("kodexbar.activity") }
                        ]

                        delegate: Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            property bool active: window.activeView === modelData.id
                            implicitWidth: segText.implicitWidth + window.s(16)
                            implicitHeight: window.s(20)
                            radius: height / 2
                            color: active ? window.chipFill : "transparent"

                            Text {
                                id: segText
                                anchors.centerIn: parent
                                text: modelData.label
                                font.family: ThemeBackend.fontFamily
                                font.weight: parent.active ? Font.Bold : Font.Normal
                                font.pixelSize: window.s(10)
                                color: parent.active ? ThemeBackend.text : ThemeBackend.overlay1
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    window.switchView(modelData.id);
                                    if (modelData.id === "memory") NoLimits.refreshMemory();
                                }
                            }
                        }
                    }

                    Item { Layout.fillWidth: true }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    visible: window.activeView === "limits"
                    color: window.cardLine
                }

                StackLayout {
                    id: viewStack
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    currentIndex: window.viewIndex
                    transform: Translate { id: viewShift }

                Flickable {
                    id: flick
                                        Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: cardsColumn.implicitHeight

                    ColumnLayout {
                        id: cardsColumn
                        width: flick.width
                        spacing: window.s(9)

                        Repeater {
                            model: NoLimits.cards

                            delegate: Rectangle {
                                id: card
                                property var entry: modelData.entry
                                property var rows: modelData.rows

                                Layout.fillWidth: true
                                Layout.preferredHeight: cardCol.implicitHeight + window.s(18)
                                radius: window.s(14)
                                color: ThemeBackend.surface0
                                border.width: 0
                                opacity: window.isDisabled(card.entry.provider) ? 0.45 : 1.0
                                Behavior on opacity { NumberAnimation { duration: 200 } }

                                ColumnLayout {
                                    id: cardCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: window.s(12)
                                    anchors.rightMargin: window.s(12)
                                    spacing: window.s(7)

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: window.s(8)

                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            width: window.s(28)
                                            height: width
                                            radius: window.s(9)
                                            color: window.chipFill
                                            border.width: 0

                                            Image {
                                                anchors.centerIn: parent
                                                visible: source != ""
                                                source: window.providerIcon(card.entry.provider)
                                                sourceSize.width: window.s(17)
                                                sourceSize.height: window.s(17)
                                                width: window.s(17)
                                                height: window.s(17)
                                                fillMode: Image.PreserveAspectFit
                                                smooth: true
                                            }

                                            Text {
                                                anchors.centerIn: parent
                                                visible: window.providerIcon(card.entry.provider) === ""
                                                text: window.providerBadge(card.entry.provider)
                                                font.family: ThemeBackend.fontFamily
                                                font.weight: Font.Black
                                                font.pixelSize: window.s(11)
                                                color: ThemeBackend.subtext1
                                            }
                                        }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: window.providerName(card.entry.provider)
                                            font.family: ThemeBackend.fontFamily
                                            font.weight: Font.Bold
                                            font.pixelSize: window.s(12)
                                            color: ThemeBackend.text
                                        }

                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            visible: {
                                                let ident = card.entry.usage && card.entry.usage.identity;
                                                if (!ident || !ident.loginMethod) return false;
                                                return String(ident.loginMethod).toLowerCase() !== String(window.providerName(card.entry.provider)).toLowerCase();
                                            }
                                            radius: height / 2
                                            color: Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.7)
                                            implicitWidth: planText.implicitWidth + window.s(10)
                                            implicitHeight: window.s(15)

                                            Text {
                                                id: planText
                                                anchors.centerIn: parent
                                                text: {
                                                    let ident = card.entry.usage && card.entry.usage.identity;
                                                    return (ident && ident.loginMethod) ? ident.loginMethod : "";
                                                }
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(9)
                                                color: ThemeBackend.overlay2
                                            }
                                        }

                                        Item { Layout.fillWidth: true }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            visible: !!(card.entry && card.entry.error)
                                            text: (card.entry && card.entry.error && card.entry.error.message) ? card.entry.error.message : "erro"
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(9)
                                            color: ThemeBackend.red
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: window.s(120)
                                        }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            visible: !(card.entry && card.entry.error) && !!(card.entry && card.entry.credits && card.entry.credits.remaining !== undefined)
                                            text: (card.entry && card.entry.credits && card.entry.credits.remaining !== undefined) ? ("󰋚 " + card.entry.credits.remaining) : ""
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(9)
                                            color: ThemeBackend.overlay1
                                        }

                                        Item {
                                            id: toggleSwitch
                                            Layout.alignment: Qt.AlignVCenter
                                            implicitWidth: window.s(30)
                                            implicitHeight: window.s(17)
                                            property bool on: !window.isDisabled(card.entry.provider)

                                            Rectangle {
                                                anchors.fill: parent
                                                radius: height / 2
                                                color: toggleSwitch.on
                                                    ? Qt.rgba(ThemeBackend.green.r, ThemeBackend.green.g, ThemeBackend.green.b, 0.28)
                                                    : Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.8)
                                                border.width: 1
                                                border.color: toggleSwitch.on
                                                    ? Qt.rgba(ThemeBackend.green.r, ThemeBackend.green.g, ThemeBackend.green.b, 0.8)
                                                    : Qt.rgba(ThemeBackend.overlay0.r, ThemeBackend.overlay0.g, ThemeBackend.overlay0.b, 0.5)
                                                Behavior on color { ColorAnimation { duration: 180 } }

                                                Rectangle {
                                                    width: parent.height - window.s(4)
                                                    height: width
                                                    radius: width / 2
                                                    y: window.s(2)
                                                    x: toggleSwitch.on ? (parent.width - width - window.s(2)) : window.s(2)
                                                    color: toggleSwitch.on ? ThemeBackend.green : ThemeBackend.overlay1
                                                    Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                                    Behavior on color { ColorAnimation { duration: 180 } }
                                                }
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: window.toggleProvider(card.entry.provider)
                                            }
                                        }
                                    }

                                    Repeater {
                                        model: card.rows

                                        delegate: RowLayout {
                                            Layout.fillWidth: true
                                            spacing: window.s(8)
                                            visible: !(card.entry && card.entry.error)

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                Layout.preferredWidth: window.s(76)
                                                text: modelData.label
                                                font.family: ThemeBackend.fontFamily
                                                font.weight: Font.Bold
                                                font.pixelSize: window.s(10)
                                                color: (modelData.label.length > 2) ? ThemeBackend.overlay1 : ThemeBackend.overlay2
                                                elide: Text.ElideRight
                                            }

                                            Rectangle {
                                                Layout.fillWidth: true
                                                Layout.preferredHeight: window.s(8)
                                                Layout.alignment: Qt.AlignVCenter
                                                radius: height / 2
                                                color: Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.8)

                                                Rectangle {
                                                    height: parent.height
                                                    radius: parent.radius
                                                    color: window.severityColor(NoLimits.severityFor(modelData.pct, card.entry.provider))
                                                    width: (modelData.pct === null) ? 0 : parent.width * Math.max(0, Math.min(100, modelData.pct)) / 100
                                                    Behavior on width { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }
                                                }
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: (modelData.pct === null) ? "—" : Math.round(modelData.pct) + "%"
                                                font.family: ThemeBackend.fontFamily
                                                font.weight: Font.Bold
                                                font.pixelSize: window.s(11)
                                                color: ThemeBackend.text
                                                Layout.preferredWidth: window.s(38)
                                                horizontalAlignment: Text.AlignRight
                                            }

                                            Rectangle {
                                                Layout.alignment: Qt.AlignVCenter
                                                Layout.preferredWidth: Math.max(window.s(46), resetText.implicitWidth + window.s(10))
                                                Layout.preferredHeight: window.s(15)
                                                radius: height / 2
                                                color: Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.6)

                                                Text {
                                                    id: resetText
                                                    anchors.centerIn: parent
                                                    text: window.fmtReset(modelData.reset)
                                                    font.family: ThemeBackend.fontFamily
                                                    font.pixelSize: window.s(9)
                                                    color: ThemeBackend.overlay2
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: !NoLimits.quotaLoading && NoLimits.cards.length === 0 && !NoLimits.quotaError
                            text: "Sem dados"
                            font.family: ThemeBackend.fontFamily
                            font.pixelSize: window.s(11)
                            color: ThemeBackend.overlay2
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }

                    Rectangle {
                        visible: flick.contentHeight > flick.height
                        width: window.s(3)
                        radius: width / 2
                        color: ThemeBackend.overlay0
                        opacity: 0.5
                        height: Math.max(window.s(28), flick.height * flick.height / Math.max(1, flick.contentHeight))
                        x: flick.width - width - window.s(2)
                        y: (flick.height - height) * (flick.contentY / Math.max(1, flick.contentHeight - flick.height))
                    }
                }

                Flickable {
                    id: memoryFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: memoryColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: memoryColumn
                        width: memoryFlick.width
                        spacing: window.s(9)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: statusCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: statusCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(8)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(8)

                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        width: window.s(26)
                                        height: width
                                        radius: window.s(8)
                                        color: window.chipFill
                                        clip: true

                                        Image {
                                            id: aimLogo
                                            anchors.centerIn: parent
                                            visible: NoLimits.serverUp
                                            source: NoLimits.serverUp ? NoLimits.logoUrl() : ""
                                            sourceSize.width: window.s(22)
                                            sourceSize.height: window.s(22)
                                            width: window.s(19)
                                            height: window.s(19)
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true
                                            asynchronous: true
                                        }

                                        Text {
                                            anchors.centerIn: parent
                                            visible: !(NoLimits.serverUp && aimLogo.status === Image.Ready)
                                            text: "ai"
                                            font.family: ThemeBackend.fontFamily
                                            font.weight: Font.Black
                                            font.pixelSize: window.s(11)
                                            color: ThemeBackend.subtext1
                                        }
                                    }

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: "ai-memory"
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: window.s(12)
                                        color: ThemeBackend.text
                                    }

                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: NoLimits.version !== ""
                                        radius: height / 2
                                        color: window.chipFill
                                        implicitWidth: versionText.implicitWidth + window.s(10)
                                        implicitHeight: window.s(15)

                                        Text {
                                            id: versionText
                                            anchors.centerIn: parent
                                            text: NoLimits.version
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(9)
                                            color: ThemeBackend.overlay2
                                        }
                                    }

                                    Item { Layout.fillWidth: true }

                                    RowLayout {
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: window.s(5)

                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            width: window.s(7)
                                            height: width
                                            radius: width / 2
                                            color: NoLimits.serverUp ? ThemeBackend.green : ThemeBackend.red
                                        }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: NoLimits.serverUp ? I18n.t("kodexbar.online") : I18n.t("kodexbar.offline")
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(10)
                                            color: NoLimits.serverUp ? ThemeBackend.text : ThemeBackend.red
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: NoLimits.pagesAll + " " + I18n.t("kodexbar.pages") + " · " + NoLimits.observations + " " + I18n.t("kodexbar.observations") + " · " + NoLimits.sessions + " " + I18n.t("kodexbar.sessions") + " · " + NoLimits.fmtBytes(NoLimits.dbBytes)
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: window.s(9)
                                    color: ThemeBackend.overlay1
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: !NoLimits.serverUp
                                    text: I18n.t("kodexbar.server_hint")
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: window.s(9)
                                    color: ThemeBackend.overlay0
                                    wrapMode: Text.Wrap
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: handoffsCol.implicitHeight + window.s(18)
                            visible: NoLimits.handoffs.length > 0
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: handoffsCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(7)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(7)

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: I18n.t("kodexbar.open_handoffs")
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: window.s(11)
                                        color: ThemeBackend.text
                                    }

                                    Rectangle {
                                        Layout.alignment: Qt.AlignVCenter
                                        radius: height / 2
                                        color: window.chipFill
                                        implicitWidth: handoffCountText.implicitWidth + window.s(10)
                                        implicitHeight: window.s(15)

                                        Text {
                                            id: handoffCountText
                                            anchors.centerIn: parent
                                            text: "" + NoLimits.handoffs.length
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(9)
                                            color: ThemeBackend.overlay2
                                        }
                                    }

                                    Item { Layout.fillWidth: true }
                                }

                                Repeater {
                                    model: NoLimits.handoffs

                                    delegate: Rectangle {
                                        id: handoffCard
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: hCol.implicitHeight + window.s(14)
                                        radius: window.s(10)
                                        color: window.chipFill

                                        ColumnLayout {
                                            id: hCol
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.leftMargin: window.s(10)
                                            anchors.rightMargin: window.s(10)
                                            spacing: window.s(3)

                                            RowLayout {
                                                Layout.fillWidth: true
                                                spacing: window.s(6)

                                                Text {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    text: modelData.agent || "agent"
                                                    font.family: ThemeBackend.fontFamily
                                                    font.weight: Font.Bold
                                                    font.pixelSize: window.s(11)
                                                    color: ThemeBackend.text
                                                }

                                                Rectangle {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    visible: (modelData.state || "") !== ""
                                                    radius: height / 2
                                                    color: window.chipFill
                                                    implicitWidth: stateText.implicitWidth + window.s(10)
                                                    implicitHeight: window.s(14)

                                                    Text {
                                                        id: stateText
                                                        anchors.centerIn: parent
                                                        text: modelData.state || ""
                                                        font.family: ThemeBackend.fontFamily
                                                        font.pixelSize: window.s(8)
                                                        color: ThemeBackend.overlay2
                                                    }
                                                }

                                                Item { Layout.fillWidth: true }

                                                Text {
                                                    Layout.alignment: Qt.AlignVCenter
                                                    text: NoLimits.fmtWhen(modelData.at)
                                                    font.family: ThemeBackend.fontFamily
                                                    font.pixelSize: window.s(8)
                                                    color: ThemeBackend.overlay1
                                                }
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                visible: (modelData.summary || "") !== ""
                                                text: modelData.summary || ""
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(10)
                                                color: ThemeBackend.subtext0
                                                wrapMode: Text.Wrap
                                                maximumLineCount: 2
                                                elide: Text.ElideRight
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: recentCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: recentCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(7)

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: I18n.t("kodexbar.recent")
                                    font.family: ThemeBackend.fontFamily
                                    font.weight: Font.Bold
                                    font.pixelSize: window.s(11)
                                    color: ThemeBackend.text
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: NoLimits.recentPages.length === 0
                                    text: I18n.t("kodexbar.no_pages")
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: window.s(10)
                                    color: ThemeBackend.overlay1
                                }

                                Repeater {
                                    model: NoLimits.recentPages

                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: window.s(30)
                                        radius: window.s(10)
                                        color: window.chipFill

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: window.s(10)
                                            anchors.rightMargin: window.s(10)
                                            spacing: window.s(6)

                                            Text {
                                                Layout.fillWidth: true
                                                Layout.alignment: Qt.AlignVCenter
                                                text: modelData.title || modelData.path || ""
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(10)
                                                color: ThemeBackend.text
                                                elide: Text.ElideRight
                                            }

                                            Rectangle {
                                                Layout.alignment: Qt.AlignVCenter
                                                visible: (modelData.kind || "") !== ""
                                                radius: height / 2
                                                color: window.chipFill
                                                implicitWidth: kindText.implicitWidth + window.s(10)
                                                implicitHeight: window.s(14)

                                                Text {
                                                    id: kindText
                                                    anchors.centerIn: parent
                                                    text: modelData.kind || ""
                                                    font.family: ThemeBackend.fontFamily
                                                    font.pixelSize: window.s(8)
                                                    color: ThemeBackend.overlay2
                                                }
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: NoLimits.fmtWhen(modelData.updated_at)
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(8)
                                                color: ThemeBackend.overlay1
                                            }
                                        }
                                    }
                                }
                            }
                        }


                        RowLayout {
                            Layout.fillWidth: true
                            spacing: window.s(8)

                            Item { Layout.fillWidth: true }

                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: NoLimits.memoryLastRefresh > 0
                                    ? (I18n.t("kodexbar.updated") + " " + NoLimits.fmtWhen(new Date(NoLimits.memoryLastRefresh).toISOString()))
                                    : ""
                                font.family: ThemeBackend.fontFamily
                                font.pixelSize: window.s(9)
                                color: ThemeBackend.overlay0
                            }
                        }
                    }
                }

                Flickable {
                    id: activityFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: activityColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: activityColumn
                        width: activityFlick.width
                        spacing: window.s(9)


                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: consumptionCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: consumptionCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(7)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(7)

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: I18n.t("kodexbar.consumption")
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: window.s(11)
                                        color: ThemeBackend.text
                                    }

                                    Item { Layout.fillWidth: true }

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        visible: NoLimits.historySpanHours() < 1
                                        text: I18n.t("kodexbar.collecting")
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: window.s(9)
                                        color: ThemeBackend.overlay1
                                    }
                                }

                                Repeater {
                                    model: NoLimits.providers

                                    delegate: RowLayout {
                                        Layout.fillWidth: true
                                        spacing: window.s(7)

                                        Image {
                                            Layout.alignment: Qt.AlignVCenter
                                            visible: source != ""
                                            source: window.providerIcon(modelData.provider)
                                            sourceSize.width: window.s(16)
                                            sourceSize.height: window.s(16)
                                            Layout.preferredWidth: window.s(16)
                                            Layout.preferredHeight: window.s(16)
                                            fillMode: Image.PreserveAspectFit
                                            smooth: true
                                        }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: window.providerName(modelData.provider)
                                            font.family: ThemeBackend.fontFamily
                                            font.weight: Font.Bold
                                            font.pixelSize: window.s(10)
                                            color: ThemeBackend.text
                                        }

                                        Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            visible: (NoLimits.delta24h(modelData.provider) || 0) > 0
                                            radius: height / 2
                                            color: window.chipFill
                                            implicitWidth: deltaText.implicitWidth + window.s(10)
                                            implicitHeight: window.s(14)

                                            Text {
                                                id: deltaText
                                                anchors.centerIn: parent
                                                text: {
                                                    let d = NoLimits.delta24h(modelData.provider);
                                                    return d === null ? "" : ("+" + d + "%");
                                                }
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(8)
                                                color: window.severityColor(NoLimits.severityFor(NoLimits.delta24h(modelData.provider), modelData.provider))
                                            }
                                        }

                                        Item { Layout.fillWidth: true }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: {
                                                let n = NoLimits.sessionsForProvider(modelData.provider);
                                                if (n <= 0) return I18n.t("kodexbar.no_sessions_short");
                                                return (n === 1) ? I18n.t("kodexbar.sessions_one") : I18n.t("kodexbar.sessions_n", { n: n });
                                            }
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(9)
                                            color: ThemeBackend.overlay1
                                        }
                                    }
                                }
                            }
                        }


                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: eventsCol.implicitHeight + window.s(18)
                            visible: NoLimits.events.length > 0
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: eventsCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(6)

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: I18n.t("kodexbar.events")
                                    font.family: ThemeBackend.fontFamily
                                    font.weight: Font.Bold
                                    font.pixelSize: window.s(11)
                                    color: ThemeBackend.text
                                }

                                Repeater {
                                    model: NoLimits.events.slice(0, 8)

                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: window.s(26)
                                        radius: window.s(10)
                                        color: window.chipFill

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: window.s(10)
                                            anchors.rightMargin: window.s(10)
                                            spacing: window.s(6)

                                            Rectangle {
                                                Layout.alignment: Qt.AlignVCenter
                                                width: window.s(6)
                                                height: width
                                                radius: width / 2
                                                color: window.severityColor(modelData.severity)
                                            }

                                            Text {
                                                Layout.fillWidth: true
                                                Layout.alignment: Qt.AlignVCenter
                                                text: modelData.text || ""
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(10)
                                                color: ThemeBackend.text
                                                elide: Text.ElideRight
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: NoLimits.fmtWhen(new Date(modelData.t).toISOString())
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(8)
                                                color: ThemeBackend.overlay1
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: costCol.implicitHeight + window.s(18)
                            visible: NoLimits.cost.length > 0
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: costCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(7)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(7)

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: I18n.t("kodexbar.cost_30d")
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: window.s(11)
                                        color: ThemeBackend.text
                                    }

                                    Item { Layout.fillWidth: true }

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: NoLimits.fmtUsd(NoLimits.costTotal())
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: window.s(11)
                                        color: ThemeBackend.text
                                    }
                                }

                                Repeater {
                                    model: NoLimits.cost

                                    delegate: RowLayout {
                                        Layout.fillWidth: true
                                        spacing: window.s(6)

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: window.providerName(modelData.provider)
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(10)
                                            color: ThemeBackend.subtext0
                                        }

                                        Item { Layout.fillWidth: true }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            visible: modelData.projects && modelData.projects.length > 0
                                            text: (modelData.projects && modelData.projects.length > 0) ? modelData.projects[0].name : ""
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(8)
                                            color: ThemeBackend.overlay1
                                            elide: Text.ElideRight
                                            Layout.maximumWidth: window.s(140)
                                        }

                                        Text {
                                            Layout.alignment: Qt.AlignVCenter
                                            text: NoLimits.fmtUsd(modelData.cost)
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(10)
                                            color: ThemeBackend.text
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: sessionsCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: sessionsCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(7)

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: I18n.t("kodexbar.sessions_recent")
                                    font.family: ThemeBackend.fontFamily
                                    font.weight: Font.Bold
                                    font.pixelSize: window.s(11)
                                    color: ThemeBackend.text
                                }

                                Text {
                                    Layout.fillWidth: true
                                    visible: NoLimits.sessionList.length === 0
                                    text: I18n.t("kodexbar.no_sessions")
                                    font.family: ThemeBackend.fontFamily
                                    font.pixelSize: window.s(10)
                                    color: ThemeBackend.overlay1
                                }

                                Repeater {
                                    model: NoLimits.sessionList.slice(0, 8)

                                    delegate: Rectangle {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: window.s(30)
                                        radius: window.s(10)
                                        color: window.chipFill

                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: window.s(10)
                                            anchors.rightMargin: window.s(10)
                                            spacing: window.s(6)

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: window.providerName(NoLimits.agentProvider(modelData.agent_kind))
                                                font.family: ThemeBackend.fontFamily
                                                font.weight: Font.Bold
                                                font.pixelSize: window.s(10)
                                                color: ThemeBackend.text
                                            }

                                            Rectangle {
                                                Layout.alignment: Qt.AlignVCenter
                                                visible: (modelData.project || "") !== ""
                                                radius: height / 2
                                                color: window.chipFill
                                                implicitWidth: projectText.implicitWidth + window.s(10)
                                                implicitHeight: window.s(14)

                                                Text {
                                                    id: projectText
                                                    anchors.centerIn: parent
                                                    text: modelData.project || ""
                                                    font.family: ThemeBackend.fontFamily
                                                    font.pixelSize: window.s(8)
                                                    color: ThemeBackend.overlay2
                                                    elide: Text.ElideRight
                                                }
                                            }

                                            Item { Layout.fillWidth: true }

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: modelData.ended_at ? NoLimits.fmtWhen(modelData.started_at) : I18n.t("kodexbar.running")
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(8)
                                                color: ThemeBackend.overlay1
                                            }

                                            Text {
                                                Layout.alignment: Qt.AlignVCenter
                                                text: (modelData.observation_count !== undefined && modelData.observation_count !== null) ? ("" + modelData.observation_count) : ""
                                                font.family: ThemeBackend.fontFamily
                                                font.pixelSize: window.s(8)
                                                color: ThemeBackend.overlay0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Flickable {
                    id: settingsFlick
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: width
                    contentHeight: settingsColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: settingsColumn
                        width: settingsFlick.width
                        spacing: window.s(9)

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: barModeCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: barModeCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(8)

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: I18n.t("kodexbar.settings_bar")
                                    font.family: ThemeBackend.fontFamily
                                    font.weight: Font.Bold
                                    font.pixelSize: window.s(11)
                                    color: ThemeBackend.text
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(6)

                                    Repeater {
                                        model: [
                                                            { id: "alerts", label: I18n.t("kodexbar.mode_alerts") },
                                            { id: "worst", label: I18n.t("kodexbar.mode_worst") },
                                            { id: "full", label: I18n.t("kodexbar.mode_full") }
                                        ]

                                        delegate: Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            property bool active: window.displayMode === modelData.id
                                            implicitWidth: gearModeText.implicitWidth + window.s(16)
                                            implicitHeight: window.s(20)
                                            radius: height / 2
                                            color: active ? window.chipFill : "transparent"

                                            Text {
                                                id: gearModeText
                                                anchors.centerIn: parent
                                                text: modelData.label
                                                font.family: ThemeBackend.fontFamily
                                                font.weight: parent.active ? Font.Bold : Font.Normal
                                                font.pixelSize: window.s(10)
                                                color: parent.active ? ThemeBackend.text : ThemeBackend.overlay1
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: window.setDisplayMode(modelData.id)
                                            }
                                        }
                                    }

                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: notifyCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: notifyCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(8)

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(8)

                                    Text {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        text: I18n.t("kodexbar.settings_notify")
                                        font.family: ThemeBackend.fontFamily
                                        font.weight: Font.Bold
                                        font.pixelSize: window.s(11)
                                        color: ThemeBackend.text
                                    }

                                    Item {
                                        id: notifSwitch
                                        Layout.alignment: Qt.AlignVCenter
                                        implicitWidth: window.s(30)
                                        implicitHeight: window.s(17)
                                        property bool on: NoLimits.notifyEnabled

                                        Rectangle {
                                            anchors.fill: parent
                                            radius: height / 2
                                            color: notifSwitch.on
                                                ? Qt.rgba(ThemeBackend.green.r, ThemeBackend.green.g, ThemeBackend.green.b, 0.28)
                                                : Qt.rgba(ThemeBackend.surface1.r, ThemeBackend.surface1.g, ThemeBackend.surface1.b, 0.8)
                                            border.width: 1
                                            border.color: notifSwitch.on
                                                ? Qt.rgba(ThemeBackend.green.r, ThemeBackend.green.g, ThemeBackend.green.b, 0.8)
                                                : Qt.rgba(ThemeBackend.overlay0.r, ThemeBackend.overlay0.g, ThemeBackend.overlay0.b, 0.5)
                                            Behavior on color { ColorAnimation { duration: 180 } }

                                            Rectangle {
                                                width: parent.height - window.s(4)
                                                height: width
                                                radius: width / 2
                                                y: window.s(2)
                                                x: notifSwitch.on ? (parent.width - width - window.s(2)) : window.s(2)
                                                color: notifSwitch.on ? ThemeBackend.green : ThemeBackend.overlay1
                                                Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                                Behavior on color { ColorAnimation { duration: 180 } }
                                            }
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: NoLimits.setNotify(!notifSwitch.on)
                                        }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: window.s(6)

                                    Text {
                                        Layout.alignment: Qt.AlignVCenter
                                        text: I18n.t("kodexbar.settings_cooldown")
                                        font.family: ThemeBackend.fontFamily
                                        font.pixelSize: window.s(8)
                                        color: ThemeBackend.overlay0
                                    }

                                    Repeater {
                                        model: [
                                            { s: 300, label: "5min" },
                                            { s: 900, label: "15min" },
                                            { s: 1800, label: "30min" },
                                            { s: 3600, label: "1h" }
                                        ]

                                        delegate: Rectangle {
                                            Layout.alignment: Qt.AlignVCenter
                                            property bool active: NoLimits.notifyCooldownSecs === modelData.s
                                            implicitWidth: cdText.implicitWidth + window.s(14)
                                            implicitHeight: window.s(18)
                                            radius: height / 2
                                            color: active ? window.chipFill : "transparent"

                                            Text {
                                                id: cdText
                                                anchors.centerIn: parent
                                                text: modelData.label
                                                font.family: ThemeBackend.fontFamily
                                                font.weight: parent.active ? Font.Bold : Font.Normal
                                                font.pixelSize: window.s(9)
                                                color: parent.active ? ThemeBackend.text : ThemeBackend.overlay1
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: NoLimits.setNotifyCooldown(modelData.s)
                                            }
                                        }
                                    }

                                    Item { Layout.fillWidth: true }
                                }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: alertsCol.implicitHeight + window.s(18)
                            radius: window.s(14)
                            color: ThemeBackend.surface0

                            ColumnLayout {
                                id: alertsCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: window.s(12)
                                anchors.rightMargin: window.s(12)
                                spacing: window.s(8)

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: I18n.t("kodexbar.settings_alerts")
                                    font.family: ThemeBackend.fontFamily
                                    font.weight: Font.Bold
                                    font.pixelSize: window.s(11)
                                    color: ThemeBackend.text
                                }

                                Repeater {
                                    model: NoLimits.providers

                                    delegate: RowLayout {
                                        id: alertRow
                                        Layout.fillWidth: true
                                        spacing: window.s(4)
                                        property string pid: modelData.provider

                                        Text {
                                            Layout.fillWidth: true
                                            Layout.alignment: Qt.AlignVCenter
                                            text: NoLimits.providerName(alertRow.pid)
                                            font.family: ThemeBackend.fontFamily
                                            font.pixelSize: window.s(9)
                                            color: ThemeBackend.text
                                            elide: Text.ElideRight
                                        }

                                        Repeater {
                                            model: [
                                                { w: 40, c: 70 },
                                                { w: 50, c: 80 },
                                                { w: 60, c: 90 }
                                            ]

                                            delegate: Rectangle {
                                                Layout.alignment: Qt.AlignVCenter
                                                property var th: NoLimits.thresholdsFor(alertRow.pid)
                                                property bool active: th.warn === modelData.w && th.crit === modelData.c
                                                implicitWidth: alertText.implicitWidth + window.s(10)
                                                implicitHeight: window.s(18)
                                                radius: height / 2
                                                color: active ? window.chipFill : "transparent"

                                                Text {
                                                    id: alertText
                                                    anchors.centerIn: parent
                                                    text: modelData.w + "/" + modelData.c
                                                    font.family: ThemeBackend.fontFamily
                                                    font.weight: parent.active ? Font.Bold : Font.Normal
                                                    font.pixelSize: window.s(8)
                                                    color: parent.active ? ThemeBackend.text : ThemeBackend.overlay1
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: NoLimits.setThreshold(alertRow.pid, modelData.w, modelData.c)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                }
            }
        }
    }
}
