// Caelestia Extras — snippet de tema/minimalismo do WhatsApp Web.
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
// Injetado como WebEngineScript (DocumentReady) no perfil partilhado. O painel
// envia a configuração via window.__qsWaApply(cfg):
//   cfg = { wds, legacy, minimalMode, hideTabs, hideSidebar, blur, transparency }
// Cria/atualiza <style id="qs-wa">, re-aplica com MutationObserver (SPA) e
// expõe um self-test dos seletores estruturais estáveis:
//   #side, #pane-side, [data-testid], [data-navbar-item] (contrato do guia
//   de tema, lib-3). Nenhum seletor aqui inventa símbolos fora desse contrato.

(function () {
    "use strict";

    var STYLE_ID = "qs-wa";
    var SELFTEST_SELECTORS = [
        "#side",
        "#pane-side",
        "#main",
        "[data-navbar-item]",
        "[data-testid]"
    ];

    var DEFAULTS = {
        wds: {},
        legacy: {},
        minimalMode: "full",
        hideTabs: true,
        hideSidebar: true,
        blur: true,
        transparency: 0.85
    };

    function has(object, key) {
        return Object.prototype.hasOwnProperty.call(object, key);
    }

    // Converte "#RRGGBB", "#RRGGBBAA" ou "rgba(r,g,b,a)" num triplo RGB textual
    // para os pares --WDS-*-RGB / --WDS-*-rgb que o WhatsApp consome.
    function parseColor(value) {
        if (typeof value !== "string")
            return null;

        var v = value.trim();
        var m = v.match(/^#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$/);
        if (m) {
            return {
                r: parseInt(m[1].slice(0, 2), 16),
                g: parseInt(m[1].slice(2, 4), 16),
                b: parseInt(m[1].slice(4, 6), 16),
                a: m[2] ? parseInt(m[2], 16) / 255 : 1
            };
        }

        m = v.match(/^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)$/i);
        if (m) {
            return {
                r: Math.round(parseFloat(m[1])),
                g: Math.round(parseFloat(m[2])),
                b: Math.round(parseFloat(m[3])),
                a: m[4] !== undefined ? parseFloat(m[4]) : 1
            };
        }

        return null;
    }

    function rgbTriplet(value) {
        var c = parseColor(value);
        return c ? c.r + ", " + c.g + ", " + c.b : "0, 0, 0";
    }

    function decls(map, important) {
        var out = "";
        for (var key in map) {
            if (!has(map, key))
                continue;
            var name = key.indexOf("--") === 0 ? key : "--" + key;
            out += name + ":" + map[key] + (important ? " !important" : "") + ";";
        }
        return out;
    }

    // Tokens WDS: os nomes chegam sem prefixo (ex.: "accent", "surface-default").
    function wdsDecls(map, important) {
        var out = "";
        for (var key in map) {
            if (!has(map, key))
                continue;
            out += "--WDS-" + key + ":" + map[key] + (important ? " !important" : "") + ";";
        }
        return out;
    }

    function rgbDecls(map) {
        var out = "";
        for (var key in map) {
            if (!has(map, key))
                continue;
            var triplet = rgbTriplet(map[key]);
            out += "--WDS-" + key + "-RGB:" + triplet + " !important;";
            out += "--WDS-" + key + "-rgb:" + triplet + " !important;";
        }
        return out;
    }

    function buildCss(cfg) {
        var css = "";

        // 1) Contrato estável: tokens --WDS-* (+ pares -RGB/-rgb) no :root.
        css += ":root,html,body.web,.dark{" + wdsDecls(cfg.wds, true) + "}";
        css += ":root,html,body.web,.dark{" + rgbDecls(cfg.wds) + "}";

        // 2) Variáveis legadas como fallback, apontando para o contrato WDS.
        css += ":root,html,body.web,.dark{" + decls(cfg.legacy, true) + "}";

        // 3) Minimalismo estrutural.
        var full = cfg.minimalMode === "full";
        var anyMinimal = cfg.minimalMode !== "colors";

        if (anyMinimal) {
            if (cfg.hideTabs || full)
                css += "#side [data-navbar-item],#side [role=tablist]{display:none !important;}";
            css += "[data-testid^=banner-],div[role=banner]{display:none !important;}";
            css += "[data-testid=typing],[data-testid*=badge],[data-testid*=unread]{display:none !important;}";
        }

        if (full)
            css += "#main header{min-height:0 !important;padding-top:0 !important;padding-bottom:0 !important;box-shadow:none !important;}";

        // Sidebar oculta (modo "só conversa"): classe no body, ligada/desligada
        // pelo atalho configurado e pelo botão do painel.
        css += "body.qs-hide-side #side{display:none !important;}";

        // 4) Superfícies transparentes para o blob do shell aparecer atrás.
        css += "html,body,.app-wrapper-web,#app,#main,#side,#pane-side,#main header,#main footer"
             + "{background-color:transparent !important;}";

        // 5) Desfoque atrás das superfícies principais.
        if (cfg.blur)
            css += "#side,#pane-side,#main header,#main footer"
                 + "{backdrop-filter:blur(18px) saturate(140%) !important;"
                 + "-webkit-backdrop-filter:blur(18px) saturate(140%) !important;}";

        return css;
    }

    function selftest() {
        var result = { ok: true, found: {}, missing: [] };
        for (var i = 0; i < SELFTEST_SELECTORS.length; i++) {
            var selector = SELFTEST_SELECTORS[i];
            var present = !!document.querySelector(selector);
            result.found[selector] = present;
            if (!present) {
                result.ok = false;
                result.missing.push(selector);
            }
        }
        return result;
    }

    function ensureStyle(cfg) {
        var style = document.getElementById(STYLE_ID);
        if (!style) {
            style = document.createElement("style");
            style.id = STYLE_ID;
            (document.head || document.documentElement).appendChild(style);
        }
        style.textContent = buildCss(cfg);
        if (document.body)
            document.body.classList.toggle("qs-hide-side", !!cfg.hideSidebar);
        return style;
    }

    function apply(cfg) {
        var merged = {};
        for (var key in DEFAULTS) {
            if (has(DEFAULTS, key))
                merged[key] = DEFAULTS[key];
        }
        if (cfg) {
            for (var k in cfg) {
                if (has(cfg, k))
                    merged[k] = cfg[k];
            }
        }

        window.__qsWaConfig = merged;
        ensureStyle(merged);
        return selftest();
    }

    function toggleSide() {
        var cfg = window.__qsWaConfig;
        if (!cfg) {
            apply(null);
            cfg = window.__qsWaConfig;
        }
        cfg.hideSidebar = !cfg.hideSidebar;
        ensureStyle(cfg);
        return cfg.hideSidebar;
    }

    // Re-cria o <style> se o WhatsApp o remover (navegações SPA). Observa só os
    // filhos diretos de <html> para ser barato; o painel também re-aplica por
    // timer, pelo que a cobertura é dupla.
    function startObserver() {
        if (!document.documentElement || typeof MutationObserver === "undefined")
            return;

        var scheduled = false;
        var observer = new MutationObserver(function () {
            if (scheduled)
                return;
            scheduled = true;
            var run = function () {
                scheduled = false;
                if (!document.getElementById(STYLE_ID))
                    ensureStyle(window.__qsWaConfig || DEFAULTS);
            };
            if (typeof requestAnimationFrame === "function")
                requestAnimationFrame(run);
            else
                setTimeout(run, 16);
        });
        observer.observe(document.documentElement, { childList: true, subtree: false });
    }

    window.__qsWaApply = apply;
    window.__qsWaToggleSide = toggleSide;
    window.__qsWaSelftest = selftest;
    window.__qsWaBuildCss = buildCss;

    startObserver();
    apply(window.__qsWaConfig);
})();
