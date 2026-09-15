import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import QtWebEngine
import "../"
import "../reusables"

Item {
    id: window
    focus: true

    function s(val) {
        return Scaler.s(val);
    }

    property real introMain: 1
    property bool everLoaded: false
    readonly property real panelRadius: window.s(25)

    Timer {
        id: focusTimer
        interval: 60
        repeat: false
        onTriggered: window.forceActiveFocus()
    }

    Timer {
        id: webFocusTimer
        interval: 300
        repeat: false
        onTriggered: {
            if (window.visible && webLoader.item) webLoader.item.forceActiveFocus();
        }
    }

    Timer {
        id: memResetTimer
        interval: 3600000
        repeat: true
        running: true
        onTriggered: {
            if (!window.visible || window.resetPending) {
                window.resetWebMemory();
            } else {
                window.resetPending = true;
            }
        }
    }

    property bool resetPending: false

    function resetWebMemory() {
        resetPending = false;
        if (webLoader.item) webLoader.item.reload();
    }

    Timer {
        id: themeRetryTimer
        interval: 3000
        repeat: false
        onTriggered: window.injectTheme()
    }

    function resetAndPlayIntro() {
        introMain = 0;
        introAnim.restart();
    }

    onVisibleChanged: {
        if (visible) {
            forceActiveFocus();
            focusTimer.restart();
            webFocusTimer.restart();
            resetAndPlayIntro();
        } else if (resetPending) {
            resetWebMemory();
        }
    }

    ParallelAnimation {
        id: introAnim
        running: false
        NumberAnimation { target: window; property: "introMain"; from: 0; to: 1.0; duration: 800; easing.type: Easing.OutExpo }
    }

    Shortcut {
        sequence: "Ctrl+R"
        enabled: window.visible && webLoader.item
        onActivated: if (webLoader.item) webLoader.item.reload()
    }

    readonly property var waThemeVars: ({
        "--background-default": ThemeBackend.base.toString(),
        "--background-default-active": ThemeBackend.surface0.toString(),
        "--background-default-hover": ThemeBackend.surface0.toString(),
        "--app-background": ThemeBackend.base.toString(),
        "--app-background-deeper": ThemeBackend.base.toString(),
        "--panel-background-lighter": ThemeBackend.surface0.toString(),
        "--panel-background-deeper": ThemeBackend.surface0.toString(),
        "--panel-header-background": ThemeBackend.surface0.toString(),
        "--panel-header-icon": ThemeBackend.text.toString(),
        "--conversation-panel-background": ThemeBackend.base.toString(),
        "--search-container-background": ThemeBackend.surface0.toString(),
        "--search-input-container-background": ThemeBackend.surface0.toString(),
        "--search-input-background": ThemeBackend.surface1.toString(),
        "--filters-container-background": ThemeBackend.surface0.toString(),
        "--filters-item-background": ThemeBackend.surface1.toString(),
        "--compose-input-background": ThemeBackend.surface0.toString(),
        "--compose-input-background-focused": ThemeBackend.surface1.toString(),
        "--compose-input-border": ThemeBackend.surface1.toString(),
        "--incoming-background": ThemeBackend.surface0.toString(),
        "--incoming-background-deeper": ThemeBackend.surface1.toString(),
        "--outgoing-background": ThemeBackend.surface1.toString(),
        "--outgoing-background-deeper": ThemeBackend.surface2.toString(),
        "--primary": ThemeBackend.text.toString(),
        "--primary-strong": ThemeBackend.text.toString(),
        "--primary-stronger": ThemeBackend.text.toString(),
        "--secondary": ThemeBackend.subtext0.toString(),
        "--secondary-stronger": ThemeBackend.subtext1.toString(),
        "--secondary-lighter": ThemeBackend.overlay1.toString(),
        "--border-default": ThemeBackend.surface1.toString(),
        "--border-list": ThemeBackend.surface0.toString(),
        "--border-strong": ThemeBackend.surface1.toString(),
        "--icon": ThemeBackend.subtext0.toString(),
        "--icon-strong": ThemeBackend.text.toString(),
        "--icon-lighter": ThemeBackend.overlay2.toString(),
        "--dropdown-background": ThemeBackend.surface0.toString(),
        "--dropdown-background-hover": ThemeBackend.surface1.toString(),
        "--tooltip-background": ThemeBackend.surface1.toString(),
        "--tooltip-text": ThemeBackend.text.toString(),
        "--modal-backdrop": ThemeBackend.crust.toString(),
        "--unread-marker-background": "#25D366",
        "--unread-marker-text": ThemeBackend.base.toString(),
        "--link": ThemeBackend.blue.toString(),
        "--button-primary": ThemeBackend.base.toString(),
        "--button-primary-background": "#25D366",
        "--button-primary-background-hover": "#1fbe5b",
        "--button-round-background": "#25D366",
        "--chat-meta": ThemeBackend.overlay2.toString(),
        "--message-primary": ThemeBackend.text.toString(),
        "--message-secondary": ThemeBackend.overlay2.toString(),
        "--bubble-meta": ThemeBackend.overlay2.toString(),
        "--bubble-meta-icon": ThemeBackend.overlay1.toString(),
        "--ptt-green": "#25D366",
        "--progress-primary": "#25D366",
        "--avatar-placeholder-background": ThemeBackend.surface1.toString()
    })

    function injectTheme() {
        if (!webLoader.item) return;
        let vars = waThemeVars;
        let js = "(function(){try{var v=" + JSON.stringify(vars) + ";"
            + "var r=document.documentElement;"
            + "for(var k in v){r.style.setProperty(k,v[k],'important');}"
            + "r.style.setProperty('color-scheme','dark','important');"
            + "r.style.setProperty('background-color',v['--background-default'],'important');"
            + "return 'ok';}catch(e){return 'err:'+e;}})()";
        webLoader.item.runJavaScript(js);
    }

    WebEngineProfile {
        id: waProfile
        storageName: "serpantinum-whatsapp-v2"
        offTheRecord: false
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies
    }

    Component.onCompleted: {
        if (visible) {
            forceActiveFocus();
            resetAndPlayIntro();
            webFocusTimer.restart();
        }
    }

    Item {
        anchors.fill: parent
        scale: 0.95 + (0.05 * introMain)
        opacity: introMain
        transform: Translate { y: window.s(20) * (1 - introMain) }

        Rectangle {
            anchors.fill: parent
            radius: window.panelRadius
            color: ThemeBackend.base
            border.width: 0
            clip: true

            Item {
                id: webLayer
                anchors.fill: parent
                layer.enabled: true
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: webRoundMask
                }

                Loader {
                    id: webLoader
                    anchors.fill: parent
                    active: true

                    sourceComponent: WebEngineView {
                        id: web
                    anchors.fill: parent
                    focus: true
                    url: "https://web.whatsapp.com"
                    backgroundColor: ThemeBackend.base
                    profile: waProfile
                    settings.forceDarkMode: true

                    onLoadingChanged: function(loadRequest) {
                        if (loadRequest.status === WebEngineView.LoadSucceededStatus) {
                            window.everLoaded = true;
                            window.injectTheme();
                            themeRetryTimer.restart();
                        }
                    }

                    onNewWindowRequested: function(request) {
                        if (request.destination === WebEngineNewWindowRequest.InNewWindow) {
                            Quickshell.execDetached(["xdg-open", request.requestedUrl]);
                            request.reject();
                        } else {
                            request.openIn(web);
                        }
                    }

                    onPermissionRequested: function(permission) {
                        let origin = permission.origin ? permission.origin.toString() : "";
                        if (permission.permissionType === WebEnginePermission.MediaAudioCapture && origin.indexOf("whatsapp") !== -1) {
                            permission.grant();
                        } else {
                            permission.deny();
                        }
                    }

                    onRenderProcessTerminated: function(terminationStatus, exitCode) {
                        renderCrashTimer.restart();
                    }
                }
                }
            }

            Item {
                id: webRoundMask
                anchors.fill: parent
                visible: false
                layer.enabled: true

                Rectangle {
                    anchors.fill: parent
                    radius: window.panelRadius
                    color: "black"
                }
            }

            Timer {
                id: renderCrashTimer
                interval: 800
                repeat: false
                onTriggered: {
                    if (window.visible && webLoader.item) webLoader.item.reload();
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: window.panelRadius
                visible: !window.everLoaded
                color: ThemeBackend.base

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: window.s(12)

                    LoaderIcon {
                        Layout.alignment: Qt.AlignHCenter
                        width: window.s(28)
                        height: window.s(28)
                        accentColor: "#25D366"
                        running: true
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "WhatsApp"
                        font.family: ThemeBackend.fontFamily
                        font.pixelSize: window.s(12)
                        color: ThemeBackend.subtext0
                    }
                }
            }
        }
    }
}
