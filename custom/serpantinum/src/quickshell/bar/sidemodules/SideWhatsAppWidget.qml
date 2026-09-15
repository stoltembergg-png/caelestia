import QtQuick
import QtQuick.Layouts
import QtQuick.Window
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../../reusables"
import "../../"

Rectangle {
    id: sideWhatsappWidgetRoot

    property var barWindow
    property bool isSolid: false
    property bool distinctPills: barWindow ? (barWindow.distinctPills !== undefined ? barWindow.distinctPills : false) : false
    property bool moduleActive: true
    property bool isGrouped: false
    property bool isCompact: isGrouped || (isSolid && distinctPills)
    readonly property bool isRightBar: barWindow ? (barWindow.barPosition === "right") : false

    property bool isRunning: false

    property int animDuration: 600
    property real targetY: 0
    y: targetY

    Behavior on y {
        enabled: barWindow && barWindow.startupCascadeFinished && !barWindow.positionChanging
        NumberAnimation { duration: sideWhatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }

    property real verticalPadding: barWindow ? barWindow.s(isCompact ? 10 : 12) : (isCompact ? 10 : 12)
    property real baseHeight: whatsappCol.implicitHeight + (verticalPadding * 2)
    property real baseWidth: barWindow ? (isGrouped ? barWindow.barHeight - 8 : ((isSolid && distinctPills) ? barWindow.barHeight - 6 : barWindow.barHeight)) : (isGrouped ? 22 : ((isSolid && distinctPills) ? 24 : 30))

    property real targetWidth: moduleActive ? baseWidth : 0
    property real targetHeight: moduleActive ? baseHeight : 0

    function toggleApp() {
        if (typeof Caching !== "undefined" && Caching.serpantinumDir) {
            Quickshell.execDetached(["bash", Caching.serpantinumDir + "/scripts/qs_manager.sh", "toggle", "whatsapp"]);
        } else {
            Quickshell.execDetached(["bash", "-c", "xdg-open https://web.whatsapp.com >/dev/null 2>&1 &"]);
        }
    }

    FileView {
        id: activeWidgetProbe
        path: (typeof Caching !== "undefined" && Caching.runDir) ? (Caching.runDir + "/current_widget") : ""
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            let txt = text().trim();
            let widget = "";
            try {
                let parsed = JSON.parse(txt);
                if (parsed && typeof parsed === "object") widget = parsed.widget || "";
            } catch (e) {
                widget = txt;
            }
            sideWhatsappWidgetRoot.isRunning = (widget === "whatsapp");
        }
    }

    MouseArea {
        id: bgMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sideWhatsappWidgetRoot.toggleApp()
    }

    property bool isHovered: bgMouse.containsMouse
    property bool showLayout: false

    property real targetX: isRightBar ? (parent ? (parent.width - targetWidth) : 0) : 0
    x: targetX

    Behavior on x {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: sideWhatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
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
        color: sideWhatsappWidgetRoot.isGrouped ? "transparent" : (sideWhatsappWidgetRoot.isSolid ? (sideWhatsappWidgetRoot.distinctPills ? (sideWhatsappWidgetRoot.isHovered ? ThemeBackend.surface0 : Qt.darker(ThemeBackend.surface0, 1.15)) : "transparent") : (sideWhatsappWidgetRoot.isHovered ? ThemeBackend.surface0 : ThemeBackend.base))
        border.width: 0
        visible: height > 0

        Behavior on color { enabled: barWindow ? !barWindow.positionChanging : true; ColorAnimation { duration: 250 } }
    }

    Behavior on width {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: sideWhatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on height {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: sideWhatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on opacity {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: 550; easing.type: Easing.OutCubic }
    }

    transform: Translate {
        x: sideWhatsappWidgetRoot.showLayout ? 0 : (barWindow ? (sideWhatsappWidgetRoot.isRightBar ? barWindow.s(20) : barWindow.s(-20)) : (sideWhatsappWidgetRoot.isRightBar ? 20 : -20))
        Behavior on x {
            enabled: barWindow ? !barWindow.positionChanging : true
            NumberAnimation { duration: 800; easing.type: Easing.OutQuint }
        }
    }

    Timer {
        running: barWindow && barWindow.isStartupReady
        interval: 120
        onTriggered: sideWhatsappWidgetRoot.showLayout = true
    }

    Item {
        id: topArea
        width: parent.width
        height: parent.height
        anchors.centerIn: parent

        Column {
            id: whatsappCol
            anchors.centerIn: parent
            spacing: 4

            Text {
                text: ""
                anchors.horizontalCenter: parent.horizontalCenter
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: barWindow ? barWindow.s(isCompact ? 17 : 19) : (isCompact ? 17 : 19)
                color: isRunning ? "#25D366" : (isCompact ? ThemeBackend.subtext0 : ThemeBackend.overlay2)
            }

            Rectangle {
                width: 7
                height: 7
                radius: 3.5
                anchors.horizontalCenter: parent.horizontalCenter
                color: isRunning ? "#25D366" : ThemeBackend.surface2
            }
        }
    }
}
