// Portado de Serpantinum: src/quickshell/singletons/widgetcontrols/FloatingController.qml (AGPL-3.0)
// Shim de controle do host de Quick Actions. O host (lane B/QuickActions.qml)
// observa activeIndex e a signal showRequested(tab); não há sinal setIndexRequested
// por tela como no original (um único host cobre Screens.screens).

pragma Singleton

import QtQuick

QtObject {
    id: root

    property int activeIndex: 0

    signal showRequested(string tab)

    function setIndex(i) {
        const idx = parseInt(i);
        if (!isNaN(idx) && idx >= 0)
            root.activeIndex = idx;
    }

    function show(tab) {
        root.showRequested(tab === undefined || tab === null ? "" : tab);
    }
}
