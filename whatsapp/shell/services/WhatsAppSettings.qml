// WhatsAppSettings — preferências próprias do módulo WhatsApp.
//
// Persistidas em `~/.config/caelestia-whatsapp/settings.json` (JSON próprio,
// independente do `extras.json` do Caelestia). Não contém segredos: apenas
// preferências de UI. Lido/escrito com Quickshell.Io.FileView.
//
// Consumidores: Drawer (atraso de fechar), WhatsAppNotifier (ligar/desligar),
// WhatsAppSettingsPage (edição) e, futuramente, o sensor de hover do core via
// `WhatsAppSettings.getBool("openOnHover", true)`.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/caelestia-whatsapp"
    readonly property string settingsPath: root.configDir + "/settings.json"

    readonly property var defaults: ({
            "notifications": true,
            "openOnHover": true,
            "hoverDwell": 450,
            "compactMode": false
        })

    // Valores efetivos (defaults + JSON). Nunca vazio.
    property var values: ({})
    property bool loaded: false
    property bool _writing: false

    signal changed()

    function get(key, fallback) {
        const v = root.values ? root.values[key] : undefined;
        if (v !== undefined && v !== null)
            return v;
        if (fallback !== undefined)
            return fallback;
        return root.defaults[key];
    }

    function getBool(key, fallback) {
        const v = root.get(key, fallback);
        if (typeof v === "boolean")
            return v;
        if (typeof v === "number")
            return v !== 0;
        if (typeof v === "string")
            return v.toLowerCase() === "true" || v === "1";
        return Boolean(v);
    }

    function getInt(key, fallback) {
        const v = root.get(key, fallback);
        const n = typeof v === "number" ? v : parseInt(v, 10);
        return isNaN(n) ? root.defaults[key] : n;
    }

    function set(key, value) {
        const next = Object.assign({}, root.values);
        next[key] = value;
        root.values = next;
        root.persist();
        root.changed();
    }

    function persist() {
        Quickshell.execDetached(["mkdir", "-p", root.configDir]);
        root._writing = true;
        file.setText(JSON.stringify(root.values, null, 2));
    }

    function _merge(incoming) {
        const out = {};
        for (const k in root.defaults)
            out[k] = root.defaults[k];
        if (incoming && typeof incoming === "object") {
            for (const k in incoming)
                out[k] = incoming[k];
        }
        return out;
    }

    FileView {
        id: file

        path: root.settingsPath
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
            root.values = root._merge(parsed);
            root.loaded = true;
        }

        onLoadFailed: err => {
            root._writing = false;
            if (err === FileViewError.FileNotFound) {
                root.values = root._merge(({}));
                Qt.callLater(() => root.persist());
            }
            root.loaded = true;
        }
    }

    Component.onCompleted: {
        root.values = root._merge(({}));
        file.reload();
    }
}
