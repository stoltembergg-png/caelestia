// Portado de Serpantinum: src/quickshell/singletons/system/I18n.qml (AGPL-3.0)
// Shim: t(key, args) lê assets/languages/{lang}.json via FileView.
// lang vem de Config.getSetting("general").language (default "en"),
// normalizado para 2 letras; só en/pt são suportados (senão cai em en).
// Fallback: en.json e, por fim, a última parte da chave (legível).

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.extras

Item {
    id: root

    readonly property string languagesDir: Caching.serpantinumDir + "/assets/languages"
    readonly property var supportedLanguages: ["en", "pt"]

    property string currentLang: "en"
    property var translations: ({})
    property var fallbackTranslations: ({})
    property bool isReady: false

    signal languageChanged()

    function normalizeLang(rawLang) {
        if (!rawLang || typeof rawLang !== "string")
            return "en";
        let lang = rawLang.toLowerCase().replace("-", "_").split("_")[0];
        return root.supportedLanguages.indexOf(lang) !== -1 ? lang : "en";
    }

    function applyLanguage() {
        const general = Config.getSetting("general", ({}));
        const lang = normalizeLang(general ? general.language : "en");
        if (lang === root.currentLang)
            return;
        root.currentLang = lang;
        langFile.path = root.languagesDir + "/" + lang + ".json";
        langFile.reload();
        root.languageChanged();
    }

    function resolveKey(store, key) {
        if (!store)
            return null;
        const parts = key.split(".");
        let current = store;
        for (let i = 0; i < parts.length; i++) {
            if (current === null || current === undefined || current[parts[i]] === undefined)
                return null;
            current = current[parts[i]];
        }
        return typeof current === "string" ? current : null;
    }

    function fallbackText(key) {
        const parts = key.split(".");
        return parts[parts.length - 1].replace(/_/g, " ");
    }

    function t(key, args) {
        let text = resolveKey(root.translations, key);
        if (text === null)
            text = resolveKey(root.fallbackTranslations, key);
        if (text === null)
            text = fallbackText(key);

        if (args && typeof args === "object") {
            for (const k in args)
                text = text.replace(new RegExp("\\{" + k + "\\}", "g"), args[k]);
        }
        return text;
    }

    FileView {
        id: fallbackFile

        path: root.languagesDir + "/en.json"
        watchChanges: false
        printErrors: false

        onLoaded: {
            try {
                root.fallbackTranslations = JSON.parse(text());
            } catch (e) {
                root.fallbackTranslations = ({});
            }
            root.isReady = true;
        }

        onLoadFailed: {
            root.fallbackTranslations = ({});
            root.isReady = true;
        }
    }

    FileView {
        id: langFile

        path: root.languagesDir + "/en.json"
        watchChanges: false
        printErrors: false

        onLoaded: {
            try {
                root.translations = JSON.parse(text());
            } catch (e) {
                root.translations = ({});
            }
        }

        onLoadFailed: {
            root.translations = ({});
        }
    }

    Component.onCompleted: root.applyLanguage()
}
