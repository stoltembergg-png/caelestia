import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../../reusables"
import "../../"

Rectangle {
    id: sideKodexBarRoot

    property var barWindow
    property bool isSolid: false
    property bool distinctPills: barWindow ? (barWindow.distinctPills !== undefined ? barWindow.distinctPills : false) : false
    property bool moduleActive: true
    property bool isGrouped: false
    property bool isCompact: isGrouped || (isSolid && distinctPills)
    readonly property bool isRightBar: barWindow ? (barWindow.barPosition === "right") : false

    property int updateInterval: 60000
    property string panelCommand: "kodexbar-panel --format json"
    property var providers: []

    property int animDuration: 600
    property real targetY: 0
    y: targetY

    Behavior on y {
        enabled: barWindow && barWindow.startupCascadeFinished && !barWindow.positionChanging
        NumberAnimation { duration: sideKodexBarRoot.animDuration; easing.type: Easing.OutQuint }
    }

    property real verticalPadding: barWindow ? barWindow.s(isCompact ? 10 : 12) : (isCompact ? 10 : 12)
    property real baseHeight: Math.max(providersCol.implicitHeight, barWindow ? barWindow.s(18) : 18) + (verticalPadding * 2)
    property real baseWidth: barWindow ? (isGrouped ? barWindow.barHeight - 8 : ((isSolid && distinctPills) ? barWindow.barHeight - 6 : barWindow.barHeight)) : (isGrouped ? 22 : ((isSolid && distinctPills) ? 24 : 30))

    property real targetWidth: moduleActive ? baseWidth : 0
    property real targetHeight: moduleActive ? baseHeight : 0

    function openPanel() {
        if (typeof Caching !== "undefined" && Caching.serpantinumDir) {
            Quickshell.execDetached(["bash", Caching.serpantinumDir + "/scripts/qs_manager.sh", "toggle", "kodexbar"]);
        }
    }

    function severityColor(sev) {
        if (sev === "critical") return ThemeBackend.red;
        if (sev === "warning") return ThemeBackend.peach;
        return ThemeBackend.green;
    }

    MouseArea {
        id: bgMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sideKodexBarRoot.openPanel()
    }

    property bool isHovered: bgMouse.containsMouse
    property bool showLayout: false

    property real targetX: isRightBar ? (parent ? (parent.width - targetWidth) : 0) : 0
    x: targetX

    Behavior on x {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: sideKodexBarRoot.animDuration; easing.type: Easing.OutQuint }
    }

    width: targetWidth
    height: targetHeight

    color: "transparent"
    border.width: 0
    clip: true
    visible: (height > 0 || opacity > 0) && (!barWindow || !barWindow.positionChanging)
    opacity: (showLayout && moduleActive && (!barWindow || !barWindow.positionChanging)) ? ((barWindow && barWindow.barOpacity !== undefined) ? barWindow.barOpacity : 1.0) : 0.0

    Rectangle {
        id: bgRect
        z: -1
        width: parent.width
        height: parent.height
        radius: ThemeBackend.borderRadius
        color: sideKodexBarRoot.isGrouped ? "transparent" : (sideKodexBarRoot.isSolid ? (sideKodexBarRoot.distinctPills ? (sideKodexBarRoot.isHovered ? ThemeBackend.surface0 : Qt.darker(ThemeBackend.surface0, 1.15)) : "transparent") : (sideKodexBarRoot.isHovered ? ThemeBackend.surface0 : ThemeBackend.base))
        border.width: 0
        visible: height > 0

        Behavior on color { enabled: barWindow ? !barWindow.positionChanging : true; ColorAnimation { duration: 250 } }
    }

    Behavior on width {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: sideKodexBarRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on height {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: sideKodexBarRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on opacity {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: 550; easing.type: Easing.OutCubic }
    }

    transform: Translate {
        x: sideKodexBarRoot.showLayout ? 0 : (barWindow ? (sideKodexBarRoot.isRightBar ? barWindow.s(20) : barWindow.s(-20)) : (sideKodexBarRoot.isRightBar ? 20 : -20))
        Behavior on x {
            enabled: barWindow ? !barWindow.positionChanging : true
            NumberAnimation { duration: 800; easing.type: Easing.OutQuint }
        }
    }

    Timer {
        running: barWindow && barWindow.isStartupReady
        interval: 120
        onTriggered: sideKodexBarRoot.showLayout = true
    }

    Process {
        id: quotaProcess
        command: sideKodexBarRoot.moduleActive ? ["bash", "-c", sideKodexBarRoot.panelCommand] : []
        stdout: StdioCollector {
            id: quotaStdout
            onStreamFinished: {
                try {
                    let data = JSON.parse(quotaStdout.text.trim());
                    sideKodexBarRoot.providers = data.providers || [];
                } catch (e) {
                    sideKodexBarRoot.providers = [];
                }
            }
        }
        onExited: {
            if (sideKodexBarRoot.moduleActive) updateTimer.restart();
        }
    }

    Timer {
        id: updateTimer
        interval: sideKodexBarRoot.updateInterval
        repeat: false
        onTriggered: {
            if (sideKodexBarRoot.moduleActive) {
                quotaProcess.running = false;
                quotaProcess.running = true;
            }
        }
    }

    Component.onCompleted: {
        quotaProcess.running = true;
    }

    Component.onDestruction: {
        quotaProcess.running = false;
        updateTimer.stop();
    }

    Item {
        id: topArea
        width: parent.width
        height: parent.height
        anchors.centerIn: parent

        Column {
            id: providersCol
            anchors.centerIn: parent
            spacing: barWindow ? barWindow.s(4) : 4

            Repeater {
                model: sideKodexBarRoot.providers

                delegate: Row {
                    spacing: barWindow ? barWindow.s(4) : 4
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        width: barWindow ? barWindow.s(6) : 6
                        height: width
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: sideKodexBarRoot.severityColor(modelData.error ? "critical" : modelData.severity)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label || modelData.provider || "?"
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: barWindow ? barWindow.s(sideKodexBarRoot.isCompact ? 10 : 11) : (sideKodexBarRoot.isCompact ? 10 : 11)
                        font.weight: Font.Bold
                        color: sideKodexBarRoot.isHovered ? ThemeBackend.text : ThemeBackend.subtext0
                        Behavior on color { ColorAnimation { duration: 200 } }
                    }
                }
            }

            Text {
                visible: sideKodexBarRoot.providers.length === 0
                text: "—"
                anchors.horizontalCenter: parent.horizontalCenter
                font.family: ThemeBackend.fontFamily
                font.pixelSize: barWindow ? barWindow.s(11) : 11
                color: ThemeBackend.overlay2
            }
        }
    }
}
