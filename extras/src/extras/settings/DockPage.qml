// Caelestia Extras — Ajustes da dock (Nexus).
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
import qs.modules.nexus.common
import qs.extras as Extras

PageBase {
    id: root

    title: qsTr("Dock")

    // Lido a cada mudança de rawSettings; qualquer setSetting reavalia a página.
    readonly property var dockSettings: Extras.Config.getSetting("dock", {})

    // Valor da chave com fallback, sem inventar símbolo: a dock já lê estes defaults.
    function value(key, fallback) {
        const settings = root.dockSettings;
        return (settings && settings[key] !== undefined && settings[key] !== null) ? settings[key] : fallback;
    }

    // Persiste preservando as demais chaves do dock (apps, enabled, position, …).
    // A dock escuta onRawSettingsChanged e aplica ao vivo.
    function update(key, newValue) {
        const next = Object.assign({}, Extras.Config.rawSettings.dock);
        next[key] = newValue;
        Extras.Config.setSetting("dock", next);
    }

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
            text: qsTr("Sempre visível")
            subtext: qsTr("Manter a dock visível mesmo sem aplicativos fixados")
            checked: root.value("alwaysVisible", true)
            onToggled: root.update("alwaysVisible", checked)
        }

        ToggleRow {
            text: qsTr("Auto-ocultar")
            subtext: qsTr("Esconder a dock quando o cursor estiver longe dela")
            checked: root.value("autohide", false)
            onToggled: root.update("autohide", checked)
        }

        StepperRow {
            label: qsTr("Atraso para ocultar")
            subtext: qsTr("Tempo em milissegundos antes de esconder a dock")
            value: root.value("autohideTimeout", 1000)
            from: 0
            to: 5000
            stepSize: 100
            onMoved: v => root.update("autohideTimeout", Math.round(v))
        }

        // "checked" = ocultar em tela cheia; a chave grava o inverso dela.
        ToggleRow {
            text: qsTr("Ocultar em tela cheia")
            subtext: qsTr("Esconder a dock quando houver uma janela em tela cheia")
            checked: !root.value("showOnFullscreen", false)
            onToggled: root.update("showOnFullscreen", !checked)
        }

        ToggleRow {
            last: true
            text: qsTr("Reservar espaço")
            subtext: qsTr("Impedir que as janelas ocupem a área da dock")
            checked: root.value("exclusive", true)
            onToggled: root.update("exclusive", checked)
        }

        // Aparência
        SectionHeader {
            text: qsTr("Aparência")
        }

        SliderRow {
            first: true
            icon: "opacity"
            label: qsTr("Transparência")
            valueLabel: Math.round(value * 100) + "%"
            value: root.value("opacity", 100) / 100
            onMoved: v => root.update("opacity", Math.round(v * 100))
        }

        StepperRow {
            last: true
            label: qsTr("Tamanho dos ícones")
            subtext: qsTr("Tamanho dos ícones da dock em pixels")
            value: root.value("elementSize", 44)
            from: 24
            to: 96
            stepSize: 4
            onMoved: v => root.update("elementSize", Math.round(v))
        }

        // Animações
        SectionHeader {
            text: qsTr("Animações")
        }

        ToggleRow {
            first: true
            text: qsTr("Animações")
            subtext: qsTr("Ativar transições de abertura, hover e escala")
            checked: root.value("animations", true)
            onToggled: root.update("animations", checked)
        }

        SliderRow {
            icon: "animation"
            label: qsTr("Intensidade do hover")
            valueLabel: Math.round(100 + value * 100) + "%"
            value: (root.value("hoverScale", 120) - 100) / 100
            onMoved: v => root.update("hoverScale", Math.round(100 + v * 100))
        }

        ToggleRow {
            last: true
            text: qsTr("Efeito cascata")
            subtext: qsTr("Aumentar os ícones vizinhos conforme o cursor se aproxima")
            checked: root.value("cascadeScale", true)
            onToggled: root.update("cascadeScale", checked)
        }
    }
}
