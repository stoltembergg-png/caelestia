// Portado de Serpantinum: src/quickshell/singletons/theme/Scaler.qml (AGPL-3.0)
// Shim: baseScale lido do shim de Config (general.uiScale), default 1.0.
// O original expunha uiScale por monitor; no port usamos a escala global.

pragma Singleton

import QtQuick
import Quickshell
import qs.extras

Item {
    id: root
    visible: false

    readonly property real baseScale: {
        const general = Config.getSetting("general", null);
        return (general && general.uiScale !== undefined) ? Number(general.uiScale) : 1.0;
    }

    function s(val) {
        const res = val * root.baseScale;
        return isNaN(res) ? val : res;
    }
}
