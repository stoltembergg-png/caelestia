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

    title: Extras.I18n.t("dock_settings.title")

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
            text: Extras.I18n.t("dock_settings.behavior")
        }

        ToggleRow {
            first: true
            text: Extras.I18n.t("dock_settings.always_visible")
            subtext: Extras.I18n.t("dock_settings.always_visible_desc")
            checked: root.value("alwaysVisible", true)
            onToggled: root.update("alwaysVisible", checked)
        }

        ToggleRow {
            text: Extras.I18n.t("dock_settings.autohide")
            subtext: Extras.I18n.t("dock_settings.autohide_desc")
            checked: root.value("autohide", false)
            onToggled: root.update("autohide", checked)
        }

        StepperRow {
            label: Extras.I18n.t("dock_settings.autohide_delay")
            subtext: Extras.I18n.t("dock_settings.autohide_delay_desc")
            value: root.value("autohideTimeout", 1000)
            from: 0
            to: 5000
            stepSize: 100
            onMoved: v => root.update("autohideTimeout", Math.round(v))
        }

        // "checked" = ocultar em tela cheia; a chave grava o inverso dela.
        ToggleRow {
            text: Extras.I18n.t("dock_settings.fullscreen_hide")
            subtext: Extras.I18n.t("dock_settings.fullscreen_hide_desc")
            checked: !root.value("showOnFullscreen", false)
            onToggled: root.update("showOnFullscreen", !checked)
        }

        ToggleRow {
            last: true
            text: Extras.I18n.t("dock_settings.reserve_space")
            subtext: Extras.I18n.t("dock_settings.reserve_space_desc")
            checked: root.value("exclusive", true)
            onToggled: root.update("exclusive", checked)
        }

        // Aparência
        SectionHeader {
            text: Extras.I18n.t("dock_settings.appearance")
        }

        SliderRow {
            first: true
            icon: "opacity"
            label: Extras.I18n.t("dock_settings.transparency")
            valueLabel: Math.round(value * 100) + "%"
            value: root.value("opacity", 100) / 100
            onMoved: v => root.update("opacity", Math.round(v * 100))
        }

        StepperRow {
            last: true
            label: Extras.I18n.t("dock_settings.icon_size")
            subtext: Extras.I18n.t("dock_settings.icon_size_desc")
            value: root.value("elementSize", 44)
            from: 24
            to: 96
            stepSize: 4
            onMoved: v => root.update("elementSize", Math.round(v))
        }

        // Animações
        SectionHeader {
            text: Extras.I18n.t("dock_settings.animations")
        }

        ToggleRow {
            first: true
            text: Extras.I18n.t("dock_settings.animations")
            subtext: Extras.I18n.t("dock_settings.animations_desc")
            checked: root.value("animations", true)
            onToggled: root.update("animations", checked)
        }

        SliderRow {
            icon: "animation"
            label: Extras.I18n.t("dock_settings.hover_intensity")
            valueLabel: Math.round(100 + value * 100) + "%"
            value: (root.value("hoverScale", 120) - 100) / 100
            onMoved: v => root.update("hoverScale", Math.round(100 + v * 100))
        }

        ToggleRow {
            last: true
            text: Extras.I18n.t("dock_settings.cascade_effect")
            subtext: Extras.I18n.t("dock_settings.cascade_effect_desc")
            checked: root.value("cascadeScale", true)
            onToggled: root.update("cascadeScale", checked)
        }
    }
}
