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
    id: whatsappWidgetRoot

    property var barWindow
    property bool isSolid: false
    property bool distinctPills: barWindow ? (barWindow.distinctPills !== undefined ? barWindow.distinctPills : false) : false
    property bool moduleActive: true
    property bool isGrouped: false
    property bool isCompact: isGrouped || (isSolid && distinctPills)
    readonly property bool isBottomBar: barWindow ? (barWindow.barPosition === "bottom") : false

    property bool isRunning: false
    property string appId: "com.whatsapp.linux"

    property int animDuration: 600
    property real targetX: 0
    x: targetX

    Behavior on x {
        enabled: barWindow && barWindow.startupCascadeFinished && !barWindow.positionChanging
        NumberAnimation { duration: whatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }

    property real horizontalPadding: barWindow ? barWindow.s(isCompact ? 10 : 12) : (isCompact ? 10 : 12)
    property real baseWidth: whatsappRow.implicitWidth + (horizontalPadding * 2)
    property real baseHeight: barWindow ? (isGrouped ? barWindow.barHeight - 8 : ((isSolid && distinctPills) ? barWindow.barHeight - 6 : barWindow.barHeight)) : (isGrouped ? 22 : ((isSolid && distinctPills) ? 24 : 30))

    property real targetHeight: baseHeight
    property real targetWidth: moduleActive ? baseWidth : 0

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
            whatsappWidgetRoot.isRunning = (widget === "whatsapp");
        }
    }

    MouseArea {
        id: bgMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: whatsappWidgetRoot.toggleApp()
    }

    property bool isHovered: bgMouse.containsMouse
    property bool showLayout: false

    property real targetY: barWindow ? barWindow.baseOffsetY + (barWindow.barHeight - targetHeight) / 2 : 0
    y: targetY

    Behavior on y {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: whatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }

    width: targetWidth
    height: targetHeight

    color: "transparent"
    border.width: 0
    clip: true
    visible: (width > 0 || opacity > 0) && (!barWindow || !barWindow.positionChanging)
    opacity: (showLayout && moduleActive && (!barWindow || !barWindow.positionChanging)) ? ((barWindow && barWindow.barOpacity !== undefined) ? barWindow.barOpacity : 1.0) : 0.0

    Rectangle {
        id: bgRect
        z: -1
        width: parent.width
        height: parent.height
        radius: ThemeBackend.borderRadius
        color: whatsappWidgetRoot.isGrouped ? "transparent" : (whatsappWidgetRoot.isSolid ? (whatsappWidgetRoot.distinctPills ? (whatsappWidgetRoot.isHovered ? ThemeBackend.surface0 : Qt.darker(ThemeBackend.surface0, 1.15)) : "transparent") : (whatsappWidgetRoot.isHovered ? ThemeBackend.surface0 : ThemeBackend.base))
        border.width: 0
        visible: height > 0

        Behavior on color { enabled: barWindow ? !barWindow.positionChanging : true; ColorAnimation { duration: 250 } }
    }

    Behavior on width {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: whatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on height {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: whatsappWidgetRoot.animDuration; easing.type: Easing.OutQuint }
    }
    Behavior on opacity {
        enabled: barWindow ? !barWindow.positionChanging : true
        NumberAnimation { duration: 550; easing.type: Easing.OutCubic }
    }

    transform: Translate {
        y: whatsappWidgetRoot.showLayout ? 0 : (barWindow ? (whatsappWidgetRoot.isBottomBar ? barWindow.s(20) : barWindow.s(-20)) : (whatsappWidgetRoot.isBottomBar ? 20 : -20))
        Behavior on y {
            enabled: barWindow ? !barWindow.positionChanging : true
            NumberAnimation { duration: 800; easing.type: Easing.OutQuint }
        }
    }

    Timer {
        running: barWindow && barWindow.isStartupReady
        interval: 120
        onTriggered: whatsappWidgetRoot.showLayout = true
    }

    Item {
        id: topArea
        width: parent.width
        height: parent.height
        anchors.centerIn: parent

        Row {
            id: whatsappRow
            anchors.centerIn: parent
            spacing: barWindow ? barWindow.s(6) : 6

            Text {
                text: ""
                anchors.verticalCenter: parent.verticalCenter
                font.family: "JetBrainsMono Nerd Font"
                font.pixelSize: barWindow ? barWindow.s(isCompact ? 17 : 19) : (isCompact ? 17 : 19)
                color: isRunning ? "#25D366" : (isCompact ? ThemeBackend.subtext0 : ThemeBackend.overlay2)
                Behavior on color { ColorAnimation { duration: 250 } }
            }

            Text {
                text: "WhatsApp"
                anchors.verticalCenter: parent.verticalCenter
                font.family: ThemeBackend.fontFamily
                font.pixelSize: barWindow ? barWindow.s(isCompact ? 12 : 13) : (isCompact ? 12 : 13)
                font.weight: Font.Bold
                color: isHovered ? ThemeBackend.text : (isCompact ? ThemeBackend.subtext0 : ThemeBackend.text)
                visible: !isCompact
            }
        }
    }
}
