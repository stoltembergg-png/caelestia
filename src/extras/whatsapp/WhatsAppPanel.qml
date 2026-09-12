// Caelestia Extras — conteúdo do WhatsApp (lane L1).
// Copyright (C) 2025 The Caelestia Extras contributors
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
// details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Evolução do porte do Serpantinum (src/quickshell/whatsapp/WhatsAppPopup.qml):
//  * SEM fundo próprio (o blob do core desenha atrás).
//  * O WebEngine NÃO compõe dentro de item com layer/máscara (ver nota em
//    `maskedLayer`); a máscara arredondada fica desabilitada e inerte.
//  * Tema por tokens --WDS-* mapeados de Colours (contrato estável do guia de
//    tema, lib-3); as variáveis legadas ficam como fallback apontando para o
//    WDS. Alpha corrigido para CSS (#RRGGBB / rgba()), nunca #AARRGGBB.
//  * Injeção única por WebEngineScript DocumentReady (wa-theme.js) + re-aplicação
//    por MutationObserver e por timer (SPA); self-test dos seletores estruturais.
//  * Minimalismo: esconder abas/banners/typing/badges, header enxuto, sidebar
//    oculta por atalho + botão, blur/transparência.
//  * Perfil ÚNICO partilhado (WhatsAppProfile.profile); permissões, xdg-open,
//    crash reload, memReset 1h, lazy e Ctrl+R mantidos.

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import QtWebEngine
import qs.components.controls
import qs.services
import qs.extras as Extras

Item {
    id: window

    focus: true

    // Fornecidos pelo WhatsAppDrawer (ou por um host standalone).
    property var settings: ({})
    property bool shown: false
    property WebEngineProfile profile: Extras.WhatsAppProfile.profile

    signal closeRequested()

    // ---- Config (shim qs.extras.Config, secção "whatsapp") --------------
    function cfgValue(key, fallback) {
        const s = window.settings;
        const v = (s && s[key] !== undefined && s[key] !== null) ? s[key] : undefined;
        return (v === undefined || v === null) ? fallback : v;
    }

    function cfgBool(key, fallback) {
        const v = window.cfgValue(key, fallback);
        if (typeof v === "boolean")
            return v;
        if (typeof v === "number")
            return v !== 0;
        if (typeof v === "string")
            return v.toLowerCase() === "true" || v === "1";
        return Boolean(v);
    }

    function cfgNum(key, fallback) {
        const v = window.cfgValue(key, fallback);
        const n = (typeof v === "number") ? v : parseFloat(v);
        return isNaN(n) ? fallback : n;
    }

    readonly property string minimalMode: window.cfgValue("minimalMode", "full")
    readonly property bool hideTabs: window.cfgBool("hideTabs", true)
    readonly property bool hideSidebar: window.cfgBool("hideSidebar", true)
    readonly property bool blur: window.cfgBool("blur", true)
    readonly property real transparency: Math.max(0.35, Math.min(1, window.cfgNum("transparency", 85) / 100))
    readonly property string sidebarShortcut: window.cfgValue("sidebarShortcut", "Ctrl+B")

    // Estado de runtime da sidebar (o botão/atalho alterna; a config é o default).
    property bool sideHidden: window.hideSidebar

    onHideSidebarChanged: window.sideHidden = window.hideSidebar
    onSettingsChanged: if (window.everLoaded)
        window.injectTheme()

    // ---- Escala / geometria ---------------------------------------------
    function s(val) {
        return Extras.Scaler.s(val);
    }

    readonly property real headerHeight: window.s(34)
    readonly property real panelRadius: window.s(25)
    property bool everLoaded: false
    property string selftestResult: ""
    property bool resetPending: false

    // ---- Cores: Colours -> tokens WDS (contrato) ------------------------
    function hex2(n) {
        const h = Math.max(0, Math.min(255, Math.round(n))).toString(16);
        return h.length < 2 ? "0" + h : h;
    }

    // Alpha correto para CSS: opaco -> #RRGGBB, translúcido -> rgba(r,g,b,a).
    function cssColor(c, a) {
        const alpha = (a === undefined) ? c.a : a;
        const r = Math.round(c.r * 255);
        const g = Math.round(c.g * 255);
        const b = Math.round(c.b * 255);
        if (alpha >= 0.999)
            return "#" + window.hex2(r) + window.hex2(g) + window.hex2(b);
        return "rgba(" + r + "," + g + "," + b + "," + (Math.round(alpha * 1000) / 1000) + ")";
    }

    function withAlpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }

    readonly property real surfaceAlpha: window.transparency

    readonly property var wdsVars: ({
            "accent": window.cssColor(Colours.palette.m3primary),
            "accent-deemphasized": window.cssColor(Colours.palette.m3primary, 0.18),
            "accent-emphasized": window.cssColor(Colours.palette.m3primary, 1),
            "secondary-positive": window.cssColor(Colours.palette.m3success),
            "secondary-positive-deemphasized": window.cssColor(Colours.palette.m3success, 0.18),
            "secondary-negative": window.cssColor(Colours.palette.m3error),
            "secondary-negative-deemphasized": window.cssColor(Colours.palette.m3error, 0.18),
            "secondary-warning": window.cssColor(Colours.palette.m3secondaryContainer),
            "secondary-warning-deemphasized": window.cssColor(Colours.palette.m3secondaryContainer, 0.18),
            "content-default": window.cssColor(Colours.palette.m3onSurface),
            "content-deemphasized": window.cssColor(Colours.palette.m3onSurfaceVariant),
            "content-disabled": window.cssColor(Colours.palette.m3onSurface, 0.5),
            "content-on-accent": window.cssColor(Colours.tPalette.m3surfaceContainerLowest),
            "content-action-default": window.cssColor(Colours.palette.m3primary),
            "content-action-emphasized": window.cssColor(Colours.palette.m3primary),
            "content-external-link": window.cssColor(Colours.palette.m3secondary),
            "content-inverse": window.cssColor(Colours.tPalette.m3surfaceContainerLowest),
            "content-read": window.cssColor(Colours.palette.m3secondary),
            "background-wash-plain": window.cssColor(Colours.tPalette.m3surface, window.surfaceAlpha),
            "background-wash-inset": window.cssColor(Colours.tPalette.m3surface, window.surfaceAlpha),
            "background-elevated-wash-plain": window.cssColor(Colours.tPalette.m3surface, window.surfaceAlpha),
            "background-elevated-wash-inset": window.cssColor(Colours.tPalette.m3surface, window.surfaceAlpha),
            "background-dimmer": "rgba(0,0,0,0.32)",
            "modal-backdrop-solid": window.cssColor(Colours.tPalette.m3surface, 1),
            "surface-default": window.cssColor(Colours.tPalette.m3surface, window.surfaceAlpha),
            "surface-emphasized": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "surface-elevated-default": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "surface-elevated-emphasized": window.cssColor(Colours.tPalette.m3surfaceContainerHigh, window.surfaceAlpha),
            "surface-highlight": window.cssColor(Colours.palette.m3onSurface, 0.1),
            "surface-inverse": window.cssColor(Colours.palette.m3onSurface),
            "surface-pressed": window.cssColor(Colours.palette.m3onSurface, 0.2),
            "lines-divider": window.cssColor(Colours.palette.m3outlineVariant, 0.5),
            "lines-outline-default": window.cssColor(Colours.palette.m3outline),
            "lines-outline-deemphasized": window.cssColor(Colours.palette.m3outlineVariant),
            "persistent-activity-indicator": window.cssColor(Colours.palette.m3success),
            "persistent-always-black": "#000000",
            "persistent-always-white": "#ffffff",
            "persistent-always-branded": window.cssColor(Colours.palette.m3primary),
            "systems-bubble-surface-incoming": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "systems-bubble-surface-outgoing": window.cssColor(Colours.palette.m3primary, 0.18),
            "systems-bubble-content-deemphasized": window.cssColor(Colours.palette.m3onSurface, 0.6),
            "systems-bubble-surface-overlay": window.cssColor(Colours.tPalette.m3surfaceContainerHigh, window.surfaceAlpha),
            "systems-bubble-surface-system": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "systems-bubble-surface-e2e": window.cssColor(Colours.palette.m3secondaryContainer, 0.4),
            "systems-bubble-content-e2e": window.cssColor(Colours.palette.m3secondaryContainer),
            "systems-bubble-surface-business": window.cssColor(Colours.palette.m3tertiary, 0.25),
            "systems-chat-surface-composer": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "systems-chat-background-wallpaper": window.cssColor(Colours.tPalette.m3surface, window.surfaceAlpha),
            "systems-chat-foreground-wallpaper": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "systems-chat-surface-tray": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha),
            "systems-status-seen": window.cssColor(Colours.palette.m3secondary),
            "components-platform-gesture-bar": window.cssColor(Colours.tPalette.m3surfaceContainerLowest, 0.5),
            "components-platform-status-bar": window.cssColor(Colours.tPalette.m3surfaceContainerLowest, 0.8),
            "components-surface-nav-bar": window.cssColor(Colours.tPalette.m3surfaceContainer, window.surfaceAlpha)
        })

    // Variáveis legadas (fallback p/ versões antigas do WhatsApp Web), agora
    // apontando para o contrato --WDS-*.
    readonly property var legacyVars: ({
            "--background-default": "var(--WDS-surface-default)",
            "--background-default-active": "var(--WDS-surface-highlight)",
            "--background-default-hover": "var(--WDS-surface-highlight)",
            "--app-background": "var(--WDS-background-wash-plain)",
            "--app-background-deeper": "var(--WDS-background-wash-inset)",
            "--panel-background-lighter": "var(--WDS-surface-emphasized)",
            "--panel-background-deeper": "var(--WDS-surface-default)",
            "--panel-header-background": "var(--WDS-surface-emphasized)",
            "--panel-header-icon": "var(--WDS-content-default)",
            "--conversation-panel-background": "var(--WDS-systems-chat-background-wallpaper)",
            "--search-container-background": "var(--WDS-surface-default)",
            "--search-input-container-background": "var(--WDS-surface-elevated-default)",
            "--search-input-background": "var(--WDS-surface-elevated-emphasized)",
            "--filters-container-background": "var(--WDS-surface-elevated-default)",
            "--filters-item-background": "var(--WDS-surface-emphasized)",
            "--compose-input-background": "var(--WDS-systems-chat-surface-composer)",
            "--compose-input-background-focused": "var(--WDS-surface-elevated-emphasized)",
            "--compose-input-border": "var(--WDS-lines-outline-deemphasized)",
            "--incoming-background": "var(--WDS-systems-bubble-surface-incoming)",
            "--incoming-background-deeper": "var(--WDS-surface-emphasized)",
            "--outgoing-background": "var(--WDS-systems-bubble-surface-outgoing)",
            "--outgoing-background-deeper": "var(--WDS-surface-emphasized)",
            "--primary": "var(--WDS-content-default)",
            "--primary-strong": "var(--WDS-content-default)",
            "--primary-stronger": "var(--WDS-content-default)",
            "--secondary": "var(--WDS-content-deemphasized)",
            "--secondary-stronger": "var(--WDS-content-deemphasized)",
            "--secondary-lighter": "var(--WDS-content-deemphasized)",
            "--border-default": "var(--WDS-lines-outline-deemphasized)",
            "--border-list": "var(--WDS-lines-outline-deemphasized)",
            "--border-strong": "var(--WDS-lines-outline-default)",
            "--icon": "var(--WDS-content-deemphasized)",
            "--icon-strong": "var(--WDS-content-default)",
            "--icon-lighter": "var(--WDS-content-deemphasized)",
            "--dropdown-background": "var(--WDS-surface-elevated-default)",
            "--dropdown-background-hover": "var(--WDS-surface-highlight)",
            "--tooltip-background": "var(--WDS-surface-elevated-emphasized)",
            "--tooltip-text": "var(--WDS-content-default)",
            "--modal-backdrop": "var(--WDS-background-dimmer)",
            "--unread-marker-background": "var(--WDS-persistent-activity-indicator)",
            "--unread-marker-text": "var(--WDS-content-inverse)",
            "--link": "var(--WDS-content-external-link)",
            "--button-primary": "var(--WDS-content-on-accent)",
            "--button-primary-background": "var(--WDS-accent)",
            "--button-primary-background-hover": "var(--WDS-accent-emphasized)",
            "--button-round-background": "var(--WDS-accent)",
            "--chat-meta": "var(--WDS-content-deemphasized)",
            "--message-primary": "var(--WDS-content-default)",
            "--message-secondary": "var(--WDS-content-deemphasized)",
            "--bubble-meta": "var(--WDS-systems-bubble-content-deemphasized)",
            "--bubble-meta-icon": "var(--WDS-systems-bubble-content-deemphasized)",
            "--ptt-green": "var(--WDS-secondary-positive)",
            "--progress-primary": "var(--WDS-accent)",
            "--avatar-placeholder-background": "var(--WDS-surface-elevated-emphasized)"
        })

    // ---- Injeção do tema ------------------------------------------------
    function themeConfig() {
        return {
            "wds": window.wdsVars,
            "legacy": window.legacyVars,
            "minimalMode": window.minimalMode,
            "hideTabs": window.hideTabs,
            "hideSidebar": window.sideHidden,
            "blur": window.blur,
            "transparency": window.transparency
        };
    }

    function injectTheme() {
        if (!webLoader.item)
            return;
        const cfg = JSON.stringify(window.themeConfig());
        const js = "(function(){try{return window.__qsWaApply?JSON.stringify(window.__qsWaApply(" + cfg + ")):'no-injector';}catch(e){return 'err:'+e;}})()";
        webLoader.item.runJavaScript(js, function(result) {
            const text = result ? String(result) : "";
            if (text !== window.selftestResult) {
                window.selftestResult = text;
                console.log("[qs-wa] self-test:", text);
            }
        });
    }

    function toggleSidebar() {
        window.sideHidden = !window.sideHidden;
        window.injectTheme();
    }

    // ---- Foco / memória / crash -----------------------------------------
    Timer {
        id: focusTimer

        interval: 60
        repeat: false
        onTriggered: if (window.shown)
            window.forceActiveFocus()
    }

    Timer {
        id: webFocusTimer

        interval: 300
        repeat: false
        onTriggered: if (window.shown && webLoader.item)
            webLoader.item.forceActiveFocus()
    }

    onShownChanged: {
        if (window.shown) {
            window.forceActiveFocus();
            focusTimer.restart();
            webFocusTimer.restart();
        } else if (window.resetPending) {
            window.resetWebMemory();
        }
    }

    function resetWebMemory() {
        window.resetPending = false;
        if (webLoader.item)
            webLoader.item.reload();
    }

    Timer {
        id: memResetTimer

        interval: 3600000
        repeat: true
        running: true
        onTriggered: {
            if (!window.shown || window.resetPending)
                window.resetWebMemory();
            else
                window.resetPending = true;
        }
    }

    Timer {
        id: themeRetryTimer

        interval: 3000
        repeat: false
        onTriggered: window.injectTheme()
    }

    // Re-aplica no SPA (navegações internas não recarregam o DocumentReady).
    Timer {
        id: themeWatchTimer

        interval: 4000
        repeat: true
        running: window.shown && window.everLoaded
        onTriggered: window.injectTheme()
    }

    Shortcut {
        sequence: "Ctrl+R"
        enabled: window.shown && webLoader.item
        onActivated: if (webLoader.item)
            webLoader.item.reload()
    }

    Shortcut {
        sequence: window.sidebarShortcut
        enabled: window.shown && window.sidebarShortcut.length > 0
        onActivated: window.toggleSidebar()
    }

    // ---- Conteúdo -------------------------------------------------------
    Item {
        id: content

        anchors.fill: parent

        // NOTA (limitação do QtWebEngine): o WebEngine não compõe dentro de um
        // item com layer/máscara — com `layer.enabled: true` o painel fica
        // invisível. Por isso `layer.enabled` fica false de propósito; o
        // MultiEffect/roundMask permanecem declarados mas inertes. NÃO reativar.
        Item {
            id: maskedLayer

            anchors.fill: parent
            layer.enabled: false
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: roundMask
            }

            Loader {
                id: webLoader

                anchors.fill: parent
                anchors.topMargin: window.headerHeight
                active: window.shown || window.everLoaded

                sourceComponent: Component {
                    WebEngineView {
                        id: web

                        anchors.fill: parent
                        focus: true
                        url: "https://web.whatsapp.com"
                        backgroundColor: "transparent"
                        profile: window.profile
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
                            } else {
                                request.openIn(web);
                            }
                        }

                        onPermissionRequested: function(permission) {
                            let origin = permission.origin ? permission.origin.toString() : "";
                            if (permission.permissionType === WebEnginePermission.PermissionType.MediaAudioCapture && origin.indexOf("whatsapp") !== -1) {
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

            // Header nativo enxuto (superfície translúcida; sem frame opaco).
            Rectangle {
                id: header

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: window.headerHeight
                color: window.withAlpha(Colours.tPalette.m3surface, Math.min(1, 0.7 * window.transparency))

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 1
                    color: window.withAlpha(Colours.palette.m3outlineVariant, 0.4)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: window.s(14)
                    anchors.rightMargin: window.s(6)
                    spacing: window.s(2)

                    Text {
                        Layout.fillWidth: true
                        Layout.alignment: Qt.AlignVCenter
                        text: "WhatsApp"
                        color: Colours.palette.m3onSurface
                        font.family: Extras.ThemeBackend.fontFamily
                        font.pixelSize: window.s(12)
                        elide: Text.ElideRight
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignVCenter
                        type: IconButton.Text
                        icon: window.sideHidden ? "menu" : "menu_open"
                        onClicked: window.toggleSidebar()
                    }

                    IconButton {
                        Layout.alignment: Qt.AlignVCenter
                        type: IconButton.Text
                        icon: "close"
                        onClicked: window.closeRequested()
                    }
                }
            }

            // Sobreposição de carregamento (transparente; o spinner gira).
            Item {
                anchors.fill: parent
                visible: !window.everLoaded

                ColumnLayout {
                    anchors.centerIn: parent
                    spacing: window.s(12)

                    CircularIndicator {
                        Layout.alignment: Qt.AlignHCenter
                        implicitSize: window.s(28)
                        running: true
                        fgColour: "#25D366"
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "WhatsApp"
                        font.family: Extras.ThemeBackend.fontFamily
                        font.pixelSize: window.s(12)
                        color: Colours.palette.m3onSurfaceVariant
                    }
                }
            }
        }
    }

    // Máscara arredondada da superfície (irmã do maskedLayer, como no porte).
    Item {
        id: roundMask

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
        onTriggered: if (window.shown && webLoader.item)
            webLoader.item.reload()
    }
}
