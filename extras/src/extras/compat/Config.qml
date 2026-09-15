// Portado de Serpantinum: src/quickshell/singletons/system/Config.qml (AGPL-3.0)
// Shim JSON em ~/.config/caelestia/extras.json via FileView.
// Expõe settingsLoaded/dataReady/rawSettings/getSetting(section,def)/setSetting(section,value),
// com defaults para dock/bar/general/display/launcher (necessários aos lanes B/C).
// Chaves planas legadas ("dock.exclusive", "enableScrolling", ...) presentes no
// arquivo são preservadas intactas pelo merge.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.utils

Item {
    id: root

    readonly property string settingsJsonPath: `${Paths.config}/extras.json`

    readonly property var defaultSettings: ({
            "dock": {
                "enabled": true,
                "position": "bottom",
                "elementSize": 44,
                "floating": false,
                "editing": false,
                "apps": [],
                "alwaysVisible": true,
                "showOnFullscreen": false,
                "animations": true,
                "exclusive": true,
                "autohide": false,
                "autohideTimeout": 1000,
                "opacity": 100,
                "hoverScale": 120,
                "cascadeScale": true,
                "sensorHeight": 6
            },
            "bar": {
                "position": "top",
                "autohide": false,
                "style": "modular"
            },
            "whatsapp": {
                "openOnHover": true,
                "hoverDwell": 450,
                "hideDelay": 300,
                "minimalMode": "full",
                "hideSidebar": true,
                "hideTabs": true,
                "blur": true,
                "transparency": 85,
                "unloadOnClose": false,
                "fullscreenHide": true,
                "sidebarShortcut": "Ctrl+B"
            },
            "general": {
                "uiScale": 1.0,
                // Vazio = seguir o locale do sistema (mesmo comportamento do core Caelestia).
                "language": ""
            },
            "display": {
                "monitors": {}
            },
            "launcher": {}
        })

    property bool dataReady: false
    property var rawSettings: ({})
    property bool _writing: false

    signal settingsLoaded()

    function mergeSettings(base, incoming) {
        const out = {};
        for (const k in base)
            out[k] = base[k];
        for (const k in incoming) {
            const b = out[k];
            const i = incoming[k];
            const bothObjects = b && i && typeof b === "object" && typeof i === "object" && !Array.isArray(b) && !Array.isArray(i);
            out[k] = bothObjects ? Object.assign({}, b, i) : i;
        }
        return out;
    }

    function getSetting(section, fallbackValue) {
        if (rawSettings && rawSettings.hasOwnProperty(section) && rawSettings[section] !== undefined)
            return rawSettings[section];
        return fallbackValue;
    }

    function setSetting(section, value) {
        const next = Object.assign({}, rawSettings);
        next[section] = value;
        rawSettings = next;
        persist();
    }

    function persist() {
        if (!settingsJsonPath)
            return;
        Quickshell.execDetached(["mkdir", "-p", Paths.config]);
        root._writing = true;
        settingsFile.setText(JSON.stringify(rawSettings, null, 2));
    }

    FileView {
        id: settingsFile

        path: root.settingsJsonPath
        watchChanges: false
        printErrors: false

        onLoaded: {
            root._writing = false;
            let parsed = ({});
            try {
                const raw = text();
                if (raw && raw.trim().length > 0)
                    parsed = JSON.parse(raw);
            } catch (e) {
                parsed = ({});
            }
            root.rawSettings = root.mergeSettings(root.defaultSettings, parsed);
            root.dataReady = true;
            root.settingsLoaded();
        }

        onLoadFailed: err => {
            root._writing = false;
            if (err === FileViewError.FileNotFound) {
                Quickshell.execDetached(["mkdir", "-p", Paths.config]);
                root.rawSettings = root.mergeSettings(root.defaultSettings, ({}));
                Qt.callLater(() => {
                    root._writing = true;
                    settingsFile.setText(JSON.stringify(root.rawSettings, null, 2));
                });
            }
            root.dataReady = true;
            root.settingsLoaded();
        }
    }

    Component.onCompleted: {
        // Garante que rawSettings nunca fique vazio antes do load terminar.
        root.rawSettings = root.mergeSettings(root.defaultSettings, ({}));
        settingsFile.reload();
    }
}
