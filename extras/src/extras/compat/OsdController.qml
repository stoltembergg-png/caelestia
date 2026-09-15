// Portado de Serpantinum: src/quickshell/singletons/widgetcontrols/OsdController.qml (AGPL-3.0)
// Shim: no port só é consumido isFullscreen (Dock). Deriva do toplevel ativo
// do Hypr via lastIpcObject.fullscreen.

pragma Singleton

import QtQuick
import Quickshell
import qs.services

Item {
    id: root

    readonly property bool isFullscreen: Boolean(Hypr.activeToplevel?.lastIpcObject?.fullscreen ?? false)
}
