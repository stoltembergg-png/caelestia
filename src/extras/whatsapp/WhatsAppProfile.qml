// Caelestia Extras — perfil WebEngine ÚNICO e compartilhado do WhatsApp.
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
// Registro: singleton no qmldir RAIZ do módulo (src/extras/qmldir):
//   singleton WhatsAppProfile 1.0 whatsapp/WhatsAppProfile.qml
//
// `storageName` é imutável ("serpantinum-whatsapp-v2"): é o diretório que já
// guarda a sessão/login do utilizador. Trocar o nome desloga. Como só pode
// existir UM WebEngineProfile por storageName no processo, este é o único
// perfil do WhatsApp — o drawer/painel e o fallback apontam para `profile`.
//
// O tema (wa-theme.js) entra como WebEngineScript DocumentReady no próprio
// perfil: assim fica registado ANTES do primeiro navigation da view e não
// depende do ciclo de vida do Loader.

pragma Singleton

import QtQuick
import Quickshell
import QtWebEngine

Singleton {
    id: root

    readonly property WebEngineProfile profile: webProfile

    WebEngineProfile {
        id: webProfile

        storageName: "serpantinum-whatsapp-v2"
        offTheRecord: false
        httpUserAgent: "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        persistentCookiesPolicy: WebEngineProfile.ForcePersistentCookies

        // Snippet de tema/minimalismo (style#qs-wa + observer + self-test).
        // Em Qt6 `WebEngineScript` é um value type (não criável diretamente):
        // instancia-se pelo singleton `WebEngine.script()` e insere-se na
        // coleção do perfil, antes do primeiro navigation da view.
        Component.onCompleted: {
            const script = WebEngine.script();
            script.name = "qs-wa-theme";
            script.sourceUrl = Qt.resolvedUrl("wa-theme.js");
            script.injectionPoint = WebEngineScript.DocumentReady;
            script.worldId = WebEngineScript.MainWorld;
            script.runsOnSubFrames = false;
            webProfile.userScripts.insert(script);
        }
    }
}
