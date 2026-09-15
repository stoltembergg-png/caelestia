import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../reusables"
import "../../"

Rectangle {
    id: kodexBarWidgetRoot

    property var barWindow
    property bool isSolid: false
    property bool distinctPills: barWindow ? (barWindow.distinctPills !== undefined ? barWindow.distinctPills : false) : false
    property bool moduleActive: true
    property bool isGrouped: false
    property bool isCompact: isGrouped || (isSolid && distinctPills)
    readonly property bool isBottomBar: barWindow ? (barWindow.barPosition === "bottom") : false

    property bool isHovered: false

    readonly property bool hasHandoffs: NoLimits.pendingHandoffs > 0
    readonly property bool serverDown: NoLimits.memoryEnabled && !NoLimits.serverUp
    property int animDuration: 600

    readonly property var providers: NoLimits.providers
    readonly property string displayMode: NoLimits.displayMode
    readonly property var disabledList: NoLimits.disabledList
    readonly property real providerIconSize: barWindow ? barWindow.s(isCompact ? 15 : 16) : (isCompact ? 15 : 16)

    function isDisabled(id) {
        return NoLimits.isDisabled(id);
    }

    readonly property string statusText: {
        if (NoLimits.quotaLoading && providers.length === 0) return "…";
        if (NoLimits.quotaError && providers.length === 0) return "ERR";
        return "";
    }

    function enabledProviders() {
        let out = [];
        for (let i = 0; i < providers.length; i++) {
            if (!isDisabled(providers[i].provider)) out.push(providers[i]);
        }
        return out;
    }

    function shownProviders() {
        let list = enabledProviders();
        if (displayMode !== "alerts") return list;
        let alerts = [];
        for (let i = 0; i < list.length; i++) {
            let p = list[i];
            if (p.error || p.severity === "warning" || p.severity === "critical") alerts.push(p);
        }
        return alerts;
    }

    function worstPct(p) {
        let vals = [];
        if (p && p.percentages) {
            if (typeof p.percentages.session === "number") vals.push(p.percentages.session);
            if (typeof p.percentages.weekly === "number") vals.push(p.percentages.weekly);
        }
        if (vals.length === 0) return null;
        let worst = vals[0];
        for (let i = 1; i < vals.length; i++) if (vals[i] > worst) worst = vals[i];
        return Math.round(worst);
    }

    function severityRank(sev) {
        if (sev === "critical") return 2;
        if (sev === "warning") return 1;
        return 0;
    }

    function worstSeverity() {
        let list = enabledProviders();
        let worst = "ok";
        for (let i = 0; i < list.length; i++) {
            let s = list[i].error ? "critical" : list[i].severity;
            if (severityRank(s) > severityRank(worst)) worst = s;
        }
        if (displayMode === "alerts" && list.length === 0) worst = "ok";
        return worst;
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

    function cycleDisplayMode() {
        let order = ["alerts", "worst", "full"];
        let idx = order.indexOf(displayMode);
        let next = order[(idx + 1) % order.length];
        NoLimits.setDisplayMode(next);
    }

    function providerIcon(id) {
        let p = String(id || "").toLowerCase();
        let home = (typeof Quickshell !== "undefined" && Quickshell.env) ? Quickshell.env("HOME") : "";
        if (p === "codex") return "file://" + home + "/.local/share/icons/hicolor/scalable/apps/codex.svg";
        if (p === "opencodego") return "file://" + home + "/.local/share/icons/hicolor/512x512/apps/ai.opencode.desktop.png";
        if (p === "cursor") return "file://" + home + "/.local/share/icons/hicolor/32x32/apps/co.anysphere.cursor.png";
        return "";
    }

    property real _anchorX: -99999
    property real _anchorW: -1

    function publishAnchor() {
        if (!barWindow || barWindow.isVertical) return;
        if (typeof Caching === "undefined" || !Caching.runDir) return;
        let pos = kodexBarWidgetRoot.mapToItem(null, 0, 0);
        let ax = Math.round(pos.x + (barWindow.margins ? barWindow.margins.left : 0));
        let aw = Math.round(kodexBarWidgetRoot.width);
        if (ax === _anchorX && aw === _anchorW) return;
        _anchorX = ax;
        _anchorW = aw;
        Quickshell.execDetached(["bash", "-c", "echo '" + JSON.stringify({ x: ax, w: aw }) + "' > " + Caching.runDir + "/kodexbar_anchor.json"]);
    }

    Timer {
        interval: 500
        repeat: true
        running: kodexBarWidgetRoot.moduleActive && kodexBarWidgetRoot.visible
        onTriggered: kodexBarWidgetRoot.publishAnchor()
    }

    onWidthChanged: publishAnchor()
    onVisibleChanged: {
        if (visible) publishAnchor();
    }

    function openPanel() {
        if (typeof Caching !== "undefined" && Caching.serpantinumDir) {
            Quickshell.execDetached(["bash", Caching.serpantinumDir + "/scripts/qs_manager.sh", "toggle", "kodexbar"]);
        }
    }

    property real horizontalPadding: barWindow ? barWindow.s(isCompact ? 7 : 9) : (isCompact ? 7 : 9)
    property real innerSpacing: barWindow ? barWindow.s(isCompact ? 6 : 8) : (isCompact ? 6 : 8)

    property real targetX: 0
    x: targetX

    Behavior on x {
        enabled: barWindow && barWindow.startupCascadeFinished && !barWindow.positionChanging
        NumberAnimation { duration: kodexBarWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }

    property real targetHeight: barWindow ? (isGrouped ? barWindow.barHeight - 8 : ((isSolid && distinctPills) ? barWindow.barHeight - 6 : barWindow.barHeight)) : (isGrouped ? 22 : ((isSolid && distinctPills) ? 24 : 30))
    property real targetWidth: moduleActive ? (textRow.implicitWidth + horizontalPadding * 2) : 0

    property real targetY: barWindow ? barWindow.baseOffsetY + (barWindow.barHeight - targetHeight) / 2 : 0
    y: targetY

    Behavior on y {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: kodexBarWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }

    width: targetWidth
    height: targetHeight

    color: "transparent"
    border.width: 0
    clip: true
    visible: (width > 0 || opacity > 0) && (!barWindow || !barWindow.positionChanging)
    opacity: (moduleActive && (!barWindow || !barWindow.positionChanging)) ? ((barWindow && barWindow.barOpacity !== undefined) ? barWindow.barOpacity : 1.0) : 0.0

    Rectangle {
        id: bgRect
        z: -1
        width: parent.width
        height: parent.height
        radius: ThemeBackend.borderRadius
        color: kodexBarWidgetRoot.isGrouped ? "transparent" : (kodexBarWidgetRoot.isSolid ? (kodexBarWidgetRoot.distinctPills ? (kodexBarWidgetRoot.isHovered ? ThemeBackend.surface0 : Qt.darker(ThemeBackend.surface0, 1.15)) : "transparent") : (kodexBarWidgetRoot.isHovered ? ThemeBackend.surface0 : ThemeBackend.base))
        border.width: 0
        visible: height > 0

        Behavior on color { enabled: barWindow ? !barWindow.positionChanging : true; ColorAnimation { duration: 250 } }
    }

    Behavior on width {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: kodexBarWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on height {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: kodexBarWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on opacity {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: 550; easing.type: Easing.OutCubic }
    }

    transform: Translate {
        y: kodexBarWidgetRoot.showLayout ? 0 : (barWindow ? (kodexBarWidgetRoot.isBottomBar ? barWindow.s(20) : barWindow.s(-20)) : (kodexBarWidgetRoot.isBottomBar ? 20 : -20))
        Behavior on y {
            enabled: barWindow ? !barWindow.positionChanging : true
            NumberAnimation { duration: 800; easing.type: Easing.OutQuint }
        }
    }

    Timer {
        running: barWindow && barWindow.isStartupReady
        interval: 120
        onTriggered: kodexBarWidgetRoot.showLayout = true
    }

    property bool showLayout: false

    MouseArea {
        id: bgMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onEntered: kodexBarWidgetRoot.isHovered = true
        onExited: kodexBarWidgetRoot.isHovered = false
        onClicked: mouse => {
            if (mouse.button === Qt.RightButton) {
                kodexBarWidgetRoot.cycleDisplayMode();
            } else {
                kodexBarWidgetRoot.openPanel();
            }
        }
    }

    RowLayout {
        id: textRow
        anchors.centerIn: parent
        spacing: kodexBarWidgetRoot.innerSpacing

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            visible: kodexBarWidgetRoot.hasHandoffs
            radius: height / 2
            color: Qt.rgba(ThemeBackend.peach.r, ThemeBackend.peach.g, ThemeBackend.peach.b, 0.25)
            implicitWidth: handoffBadgeText.implicitWidth + (barWindow ? barWindow.s(8) : 8)
            implicitHeight: barWindow ? barWindow.s(14) : 14

            Text {
                id: handoffBadgeText
                anchors.centerIn: parent
                text: "" + NoLimits.pendingHandoffs
                font.family: ThemeBackend.fontFamily
                font.weight: Font.Bold
                font.pixelSize: barWindow ? barWindow.s(9) : 9
                color: ThemeBackend.peach
            }
        }

        Rectangle {
            Layout.alignment: Qt.AlignVCenter
            visible: kodexBarWidgetRoot.serverDown
            width: barWindow ? barWindow.s(6) : 6
            height: width
            radius: width / 2
            color: ThemeBackend.red
        }

        Repeater {
            model: kodexBarWidgetRoot.shownProviders()

            delegate: RowLayout {
                spacing: barWindow ? barWindow.s(kodexBarWidgetRoot.isCompact ? 4 : 5) : (kodexBarWidgetRoot.isCompact ? 4 : 5)

                Image {
                    Layout.alignment: Qt.AlignVCenter
                    visible: source != ""
                    source: kodexBarWidgetRoot.providerIcon(modelData.provider)
                    sourceSize.width: kodexBarWidgetRoot.providerIconSize
                    sourceSize.height: kodexBarWidgetRoot.providerIconSize
                    Layout.preferredWidth: kodexBarWidgetRoot.providerIconSize
                    Layout.preferredHeight: kodexBarWidgetRoot.providerIconSize
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    opacity: kodexBarWidgetRoot.isHovered ? 1.0 : 0.85
                    Behavior on opacity { NumberAnimation { duration: 150 } }
                }

                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    visible: kodexBarWidgetRoot.providerIcon(modelData.provider) === ""
                    width: barWindow ? barWindow.s(6) : 6
                    height: width
                    radius: width / 2
                    color: kodexBarWidgetRoot.severityColor(modelData.error ? "critical" : modelData.severity)
                }

                Text {
                    Layout.alignment: Qt.AlignVCenter
                    text: {
                        let p = modelData;
                        if (p.error) return "ERR";
                        if (kodexBarWidgetRoot.displayMode === "full") {
                            let parts = [];
                            if (p.percentages && p.percentages.session !== null && p.percentages.session !== undefined) parts.push("S " + Math.round(p.percentages.session) + "%");
                            if (p.percentages && p.percentages.weekly !== null && p.percentages.weekly !== undefined) parts.push((p.provider === "cursor" ? "M " : "W ") + Math.round(p.percentages.weekly) + "%");
                            return parts.join(" ");
                        }
                        let w = kodexBarWidgetRoot.worstPct(p);
                        return (w === null) ? "" : (w + "%");
                    }
                    font.family: ThemeBackend.fontFamily
                    font.pixelSize: barWindow ? barWindow.s(kodexBarWidgetRoot.isCompact ? 11 : 12) : (kodexBarWidgetRoot.isCompact ? 11 : 12)
                    font.weight: Font.Bold
                    color: {
                        let sev = modelData.error ? "critical" : modelData.severity;
                        if (kodexBarWidgetRoot.isHovered) return ThemeBackend.text;
                        if (sev === "ok") return ThemeBackend.subtext0;
                        return kodexBarWidgetRoot.severityColor(sev);
                    }
                    Behavior on color { ColorAnimation { duration: 200 } }
                }
            }
        }

        Text {
            visible: kodexBarWidgetRoot.shownProviders().length === 0 && kodexBarWidgetRoot.providers.length === 0
            Layout.alignment: Qt.AlignVCenter
            text: kodexBarWidgetRoot.statusText
            font.family: ThemeBackend.fontFamily
            font.pixelSize: barWindow ? barWindow.s(11) : 11
            color: ThemeBackend.overlay2
        }
    }
}
