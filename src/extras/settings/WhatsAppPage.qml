// Caelestia Extras — Ajustes do WhatsApp (Nexus).
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

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components.controls
import qs.modules.nexus.common
import qs.extras as Extras

PageBase {
    id: root

    title: qsTr("WhatsApp")

    // Lido a cada mudança de rawSettings; qualquer setSetting reavalia a página.
    readonly property var whatsappSettings: Extras.Config.getSetting("whatsapp", {})

    // Valor da chave com fallback, sem inventar símbolo: os defaults vivem no
    // compat/Config.qml e são consumidos pelo drawer/painel.
    function value(key, fallback) {
        const settings = root.whatsappSettings;
        return (settings && settings[key] !== undefined && settings[key] !== null) ? settings[key] : fallback;
    }

    // Persiste preservando as demais chaves do whatsapp (openOnHover, blur, …).
    function update(key, newValue) {
        const next = Object.assign({}, Extras.Config.getSetting("whatsapp", {}));
        next[key] = newValue;
        Extras.Config.setSetting("whatsapp", next);
    }

    // Estados do minimalismo, na mesma ordem da lista minimalModeValues.
    readonly property list<MenuItem> minimalModeItems: [
        MenuItem {
            text: qsTr("Completo")
            icon: "visibility_off"
        },
        MenuItem {
            text: qsTr("Moderado")
            icon: "visibility"
        },
        MenuItem {
            text: qsTr("Só cores")
            icon: "palette"
        }
    ]
    readonly property list<string> minimalModeValues: ["full", "moderate", "colors"]

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Comportamento
        SectionHeader {
            first: true
            text: qsTr("Comportamento")
        }

        ToggleRow {
            first: true
            text: qsTr("Abrir ao passar o mouse")
            subtext: qsTr("Abrir o painel quando o cursor parar ao lado da barra")
            checked: root.value("openOnHover", true)
            onToggled: root.update("openOnHover", checked)
        }

        StepperRow {
            label: qsTr("Tempo para abrir")
            subtext: qsTr("Tempo em milissegundos que o cursor precisa parar antes de abrir")
            value: root.value("hoverDwell", 450)
            from: 200
            to: 1500
            stepSize: 50
            onMoved: v => root.update("hoverDwell", Math.round(v))
        }

        StepperRow {
            label: qsTr("Atraso para fechar")
            subtext: qsTr("Tempo em milissegundos antes de fechar ao sair do painel")
            value: root.value("hideDelay", 300)
            from: 100
            to: 1000
            stepSize: 50
            onMoved: v => root.update("hideDelay", Math.round(v))
        }

        ToggleRow {
            last: true
            text: qsTr("Ocultar em tela cheia")
            subtext: qsTr("Esconder o painel quando houver uma janela em tela cheia")
            checked: root.value("fullscreenHide", true)
            onToggled: root.update("fullscreenHide", checked)
        }

        // Minimalismo
        SectionHeader {
            text: qsTr("Minimalismo")
        }

        SelectRow {
            first: true
            label: qsTr("Modo")
            subtext: qsTr("Quanto da interface do WhatsApp deve ser escondido")
            menuItems: root.minimalModeItems
            active: root.minimalModeItems[Math.max(0, root.minimalModeValues.indexOf(root.value("minimalMode", "full")))]
            onSelected: item => root.update("minimalMode", root.minimalModeValues[root.minimalModeItems.indexOf(item)])
        }

        ToggleRow {
            text: qsTr("Esconder abas")
            subtext: qsTr("Ocultar as abas de conversas, comunidades e novidades")
            checked: root.value("hideTabs", true)
            onToggled: root.update("hideTabs", checked)
        }

        ToggleRow {
            text: qsTr("Esconder lista de conversas")
            subtext: qsTr("Ocultar a lista lateral e deixar só a conversa aberta")
            checked: root.value("hideSidebar", true)
            onToggled: root.update("hideSidebar", checked)
        }

        TextFieldRow {
            last: true
            label: qsTr("Atalho da lista")
            subtext: qsTr("Atalho para mostrar ou esconder a lista de conversas")
            value: root.value("sidebarShortcut", "Ctrl+B")
            placeholderText: "Ctrl+B"
            onEditingFinished: v => root.update("sidebarShortcut", v)
        }

        // Aparência
        SectionHeader {
            text: qsTr("Aparência")
        }

        ToggleRow {
            first: true
            text: qsTr("Desfoque")
            subtext: qsTr("Aplicar desfoque atrás das superfícies do painel")
            checked: root.value("blur", true)
            onToggled: root.update("blur", checked)
        }

        SliderRow {
            icon: "opacity"
            label: qsTr("Transparência")
            valueLabel: Math.round(value * 100) + "%"
            value: root.value("transparency", 85) / 100
            onMoved: v => root.update("transparency", Math.round(v * 100))
        }

        ToggleRow {
            last: true
            text: qsTr("Descarregar ao fechar")
            subtext: qsTr("Descarregar a página ao fechar para economizar memória (não desloga)")
            checked: root.value("unloadOnClose", false)
            onToggled: root.update("unloadOnClose", checked)
        }
    }
}
