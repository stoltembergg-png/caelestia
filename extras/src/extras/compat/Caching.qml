// Portado de Serpantinum: src/quickshell/singletons/system/Caching.qml (AGPL-3.0)
// Shim para Paths do Caelestia. Diretórios são criados com `mkdir -p`
// (Quickshell.execDetached). Mapeamento do PORT-SPEC:
//   getStateDir(n) -> Paths.state + "/" + n
//   getRunDir(n)   -> (XDG_RUNTIME_DIR | Paths.state/run) + "/caelestia-extras-" + n
//   getLogDir(n)   -> Paths.state + "/logs/" + n
//   qsDir          -> Quickshell.shellDir
//   serpantinumDir -> Quickshell.shellDir + "/extras"
// getCacheDir/home/stateDir/runDir/logDir mantidos como compat de API.

pragma Singleton

import QtQuick
import Quickshell
import qs.utils

QtObject {
    id: root

    readonly property string qsDir: Quickshell.shellDir
    readonly property string serpantinumDir: Quickshell.shellDir + "/extras"

    readonly property string home: Paths.home
    readonly property string cacheDir: Paths.cache
    readonly property string stateDir: Paths.state
    readonly property string runRoot: Quickshell.env("XDG_RUNTIME_DIR") || (Paths.state + "/run")
    readonly property string runDir: runRoot + "/caelestia-extras"
    readonly property string logDir: Paths.state + "/logs"

    function _mkdir(path) {
        if (path)
            Quickshell.execDetached(["mkdir", "-p", path]);
        return path;
    }

    function getCacheDir(widgetName) {
        return _mkdir((!widgetName || widgetName === "caelestia-extras") ? cacheDir : (cacheDir + "/" + widgetName));
    }

    function getStateDir(widgetName) {
        return _mkdir((!widgetName || widgetName === "caelestia-extras") ? stateDir : (stateDir + "/" + widgetName));
    }

    function getRunDir(widgetName) {
        return _mkdir((!widgetName || widgetName === "caelestia-extras") ? runDir : (runRoot + "/caelestia-extras-" + widgetName));
    }

    function getLogDir(widgetName) {
        return _mkdir((!widgetName || widgetName === "caelestia-extras") ? logDir : (logDir + "/" + widgetName));
    }
}
