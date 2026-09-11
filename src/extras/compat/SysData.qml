// Portado de Serpantinum: src/quickshell/singletons/info/SysData.qml (AGPL-3.0)
// Shim no-op: mantém as propriedades e funções consumidas pelo host
// (SystemUsage/Timer do Serpantinum e prewarm do host de quick actions),
// sem os Process/watchers do original.

pragma Singleton

import QtQuick
import Quickshell

Item {
    id: root

    property int cpu: 0
    property int ramPercent: 0
    property real ramGb: 0.0
    property int temp: 0
    property real netRx: 0
    property real netTx: 0
    property int diskPercent: 0
    property real diskGb: 0.0
    property real diskTotalGb: 0.0

    property int subscribers: 0
    property bool isScanningNet: false

    function subscribe() {
    }

    function unsubscribe() {
    }

    function prewarm() {
    }

    function scanNetwork() {
    }
}
