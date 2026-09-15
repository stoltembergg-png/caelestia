// Portado de Serpantinum: src/quickshell/singletons/audio/Sounds.qml (AGPL-3.0)
// Shim no-op: o port não reproduz SFX próprios do Serpantinum.

pragma Singleton

import QtQuick
import Quickshell
import qs.extras

Item {
    id: root

    readonly property bool isMuted: {
        const general = Config.getSetting("general", null);
        return general ? general.muteSfx === true : false;
    }

    readonly property real masterVolume: {
        const general = Config.getSetting("general", null);
        const v = (general && general.sfxVolume !== undefined) ? Number(general.sfxVolume) : 100;
        return Math.max(0.0, Math.min(1.0, v / 100.0));
    }

    function play(filePath, volume, duration, overrideSfxBlock) {
    }

    function playSfx(filename, volume, duration, overrideSfxBlock) {
    }

    function playUntilStopped(filenameOrPath, volume, loop, overrideSfxBlock) {
        return -1;
    }

    function stopSfx(handleId) {
    }

    function stopAllSfx() {
    }
}
