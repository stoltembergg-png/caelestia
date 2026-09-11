// Portado de Serpantinum: src/quickshell/singletons/NoLimits.qml (AGPL-3.0)
// Motor de quota (KodexBar), ai-memory, eventos e notificações.
// N1: mantém a API pública do original e adiciona visible/show/hide/toggle +
// showRequested. Não cria servidor de notificações: o core é dono do D-Bus
// (services/Notifs.qml); as notificações saem por `gdbus call` e a ação
// "Abrir" é escutada por um `gdbus monitor` persistente.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.extras
import qs.services

Item {
    id: root

    // ---------- configuração (seção noLimits, com fallback legado) ----------
    // Defaults inline: o shim Config.getSetting() devolve o valor cru gravado
    // em extras.json (sem merge), então mesclamos aqui para tolerar configs
    // parciais.

    readonly property var nlcDefaults: ({
            "enabled": true,
            "display": "alerts",
            "disabled": [],
            "thresholds": {},
            "notify": true,
            "notifyCooldown": 900,
            "memory": {
                "enabled": true,
                "endpoint": "http://127.0.0.1:49374",
                "webPath": "/web",
                "logoPath": "/web/static/logo.png",
                "workspace": "",
                "project": "",
                "refresh": 60
            }
        })

    function _mergeObjects(base, extra) {
        if (!extra || typeof extra !== "object")
            return base;
        let out = {};
        for (let k in base)
            out[k] = base[k];
        for (let k in extra) {
            let b = out[k];
            let e = extra[k];
            if (b && e && typeof b === "object" && typeof e === "object" && !Array.isArray(b) && !Array.isArray(e))
                out[k] = _mergeObjects(b, e);
            else
                out[k] = e;
        }
        return out;
    }

    readonly property var nlc: {
        // Referência explícita para reavaliar quando o extras.json carrega/grava.
        if (!Config.rawSettings)
            return nlcDefaults;
        let legacyLimits = Config.getSetting("kodexbar", ({}));
        let legacyMemory = Config.getSetting("aiMemory", ({}));
        let stored = Config.getSetting("noLimits", ({}));
        let merged = _mergeObjects(nlcDefaults, legacyLimits);
        if (legacyMemory && typeof legacyMemory === "object")
            merged = _mergeObjects(merged, { "memory": legacyMemory });
        return _mergeObjects(merged, stored);
    }

    readonly property var memoryCfg: nlc.memory ? nlc.memory : nlcDefaults.memory

    readonly property bool enabled: nlc.enabled !== false
    readonly property string displayMode: {
        let d = nlc.display || "alerts";
        return d === "unified" ? "alerts" : d;
    }
    readonly property var disabledList: nlc.disabled || []
    readonly property var thresholds: nlc.thresholds || {}

    readonly property bool memoryEnabled: memoryCfg.enabled !== false
    readonly property string endpoint: memoryCfg.endpoint || nlcDefaults.memory.endpoint
    readonly property string webPath: memoryCfg.webPath || nlcDefaults.memory.webPath
    readonly property string logoPath: memoryCfg.logoPath || nlcDefaults.memory.logoPath
    readonly property string workspace: memoryCfg.workspace || ""
    readonly property string project: memoryCfg.project || ""
    readonly property int refreshInterval: (memoryCfg.refresh && memoryCfg.refresh >= 15) ? memoryCfg.refresh : 60

    function saveConfig(patch) {
        let next = {};
        for (let k in nlc)
            next[k] = nlc[k];
        for (let k in patch)
            next[k] = patch[k];
        Config.setSetting("noLimits", next);
    }

    function setDisplayMode(mode) {
        saveConfig({ "display": mode, "disabled": disabledList });
    }

    function toggleProvider(id) {
        let disabled = disabledList.slice();
        let idx = disabled.indexOf(id);
        if (idx === -1)
            disabled.push(id);
        else
            disabled.splice(idx, 1);
        saveConfig({ "display": displayMode, "disabled": disabled });
    }

    function setNotify(enabled) {
        saveConfig({ "notify": !!enabled, "notifyCooldown": notifyCooldownSecs });
    }

    function setNotifyCooldown(secs) {
        saveConfig({ "notify": notifyEnabled, "notifyCooldown": secs });
    }

    function thresholdsFor(pid) {
        let t = thresholds[providerId(pid)];
        let warn = (t && typeof t.warn === "number") ? t.warn : 50;
        let crit = (t && typeof t.crit === "number") ? t.crit : 80;
        return { warn: warn, crit: crit };
    }

    function setThreshold(pid, warn, crit) {
        let next = {};
        for (let k in thresholds)
            next[k] = thresholds[k];
        next[providerId(pid)] = { warn: warn, crit: crit };
        saveConfig({ "thresholds": next });
    }

    function isDisabled(id) {
        return disabledList.indexOf(id) !== -1;
    }

    // ---------- visibilidade / abertura (novo N1) ----------

    property bool visible: false

    // view ∈ {"limits","memory","activity","settings"}
    signal showRequested(string view)

    function show(view) {
        let v = (typeof view === "string" && view.length > 0) ? view : "limits";
        requestedView = v;
        visible = true;
        showRequested(v);
    }

    function hide() {
        visible = false;
    }

    function toggle() {
        if (visible)
            hide();
        else
            show(requestedView && requestedView.length > 0 ? requestedView : "limits");
    }

    // ---------- quota state ----------

    property bool quotaLoading: false
    property bool quotaError: false
    property var entries: []
    property var cards: []
    property var providers: []
    property double quotaLastRefresh: 0

    function providerId(p) {
        return String(p || "").toLowerCase();
    }

    function providerLabel(id) {
        let p = providerId(id);
        if (p === "codex")
            return "Cx";
        if (p === "claude")
            return "Cl";
        if (p === "grok")
            return "Gk";
        if (p === "antigravity")
            return "Ag";
        if (p === "opencodego")
            return "op";
        if (p === "cursor")
            return "cu";
        return p.substring(0, 2);
    }

    function severityFor(pct, pid) {
        if (pct === null || pct === undefined)
            return "ok";
        let t = thresholdsFor(pid);
        if (pct >= t.crit)
            return "critical";
        if (pct >= t.warn)
            return "warning";
        return "ok";
    }

    function buildRows(entry) {
        if (!entry || typeof entry !== "object")
            return [];
        let u = entry.usage || {};
        let rows = [];
        let cursor = providerId(entry.provider) === "cursor";

        function add(win, label) {
            if (!win || typeof win !== "object")
                return;
            let pct = (typeof win.usedPercent === "number") ? win.usedPercent : null;
            if (pct === null && !win.resetsAt)
                return;
            rows.push({ label: label, pct: pct, reset: win.resetsAt || "" });
        }

        add(u.primary, "S");
        add(u.secondary, cursor ? "M" : "W");
        add(u.tertiary, "T");

        let extras = u.extraRateWindows;
        if (Array.isArray(extras)) {
            for (let i = 0; i < extras.length; i++) {
                let ex = extras[i];
                add(ex.window, ex.title || "Extra");
            }
        }
        return rows;
    }

    function providerSeverity(entry) {
        if (entry.error)
            return "critical";
        let rows = buildRows(entry);
        let worst = null;
        for (let i = 0; i < rows.length; i++) {
            if (rows[i].pct === null)
                continue;
            worst = (worst === null) ? rows[i].pct : Math.max(worst, rows[i].pct);
        }
        return severityFor(worst, entry.provider);
    }

    function worstPct(entry) {
        let vals = [];
        let u = entry && entry.usage ? entry.usage : {};
        if (u.primary && typeof u.primary.usedPercent === "number")
            vals.push(u.primary.usedPercent);
        if (u.secondary && typeof u.secondary.usedPercent === "number")
            vals.push(u.secondary.usedPercent);
        if (vals.length === 0)
            return null;
        let worst = vals[0];
        for (let i = 1; i < vals.length; i++)
            if (vals[i] > worst)
                worst = vals[i];
        return Math.round(worst);
    }

    function rebuildQuota() {
        let built = [];
        let compact = [];
        for (let i = 0; i < entries.length; i++) {
            let e = entries[i];
            built.push({ entry: e, rows: buildRows(e) });
            let u = e.usage || {};
            compact.push({
                provider: providerId(e.provider),
                label: providerLabel(e.provider),
                percentages: {
                    session: (u.primary && typeof u.primary.usedPercent === "number") ? u.primary.usedPercent : null,
                    weekly: (u.secondary && typeof u.secondary.usedPercent === "number") ? u.secondary.usedPercent : null
                },
                severity: providerSeverity(e),
                error: !!e.error,
                error_message: e.error ? (e.error.message || "erro") : null
            });
        }
        cards = built;
        providers = compact;
    }

    function refreshQuotas() {
        if (!enabled)
            return;
        if (quotaProc.running)
            return;
        quotaLoading = true;
        quotaProc.running = false;
        quotaProc.running = true;
    }

    // ---------- memory state ----------

    property bool memoryLoading: false
    property bool serverUp: false
    property bool cliOk: false

    property string version: ""
    property string bindAddress: ""
    property int pagesLatest: 0
    property int pagesAll: 0
    property int sessions: 0
    property int observations: 0
    property real dbBytes: 0
    property int freeBytes: 0
    property string llmStatus: ""
    property string llmProvider: ""

    property string activeWorkspace: "default"
    property string activeProject: ""
    property var projects: []
    property int pendingHandoffs: 0
    property string lastObservation: ""
    property var handoffs: []
    property var recentPages: []
    property var sessionList: []
    property var rules: []
    property var cost: []
    property var events: []
    property bool notifyEnabled: nlc.notify !== false
    property int notifyCooldownSecs: (nlc.notifyCooldown && nlc.notifyCooldown >= 60) ? nlc.notifyCooldown : 900
    // Aliases literais da API congelada (config `notify`/`notifyCooldown`).
    readonly property bool notify: notifyEnabled
    readonly property int notifyCooldown: notifyCooldownSecs
    property var _prevProviders: ({})
    property var _prevHandoffIds: []
    property var _prevSessionIds: []
    property var _prevServerUp: null
    property var _notifyCooldowns: ({})
    property var _notifyIds: []
    property string _pendingNotifyView: "limits"
    property string requestedView: ""
    property var quotaHistory: []
    property double memoryLastRefresh: 0
    property double resetClock: Date.now()

    readonly property string stateDir: (typeof Caching !== "undefined" && Caching.getStateDir) ? Caching.getStateDir("nolimits") : ""

    function refreshMemory() {
        if (!memoryEnabled)
            return;
        if (memoryProc.running)
            return;
        memoryLoading = true;
        memoryProc.running = false;
        memoryProc.running = true;
    }

    function refresh() {
        refreshQuotas();
        refreshMemory();
    }

    function agentProvider(agent) {
        let a = String(agent || "").toLowerCase();
        if (a === "codex")
            return "codex";
        if (a === "open-code" || a === "opencode" || a === "opencode2")
            return "opencodego";
        if (a === "cursor")
            return "cursor";
        if (a === "claude-code")
            return "claude";
        if (a === "grok" || a === "grok-build")
            return "grok";
        if (a === "gemini-cli")
            return "gemini";
        if (a === "antigravity-cli")
            return "antigravity";
        return a;
    }

    function sessionsLast24h() {
        let cutoff = Date.now() - 24 * 3600 * 1000;
        let out = [];
        for (let i = 0; i < sessionList.length; i++) {
            let st = Date.parse(sessionList[i].started_at || "");
            if (!isNaN(st) && st >= cutoff)
                out.push(sessionList[i]);
        }
        return out;
    }

    function sessionsForProvider(pid) {
        let list = sessionsLast24h();
        let n = 0;
        for (let i = 0; i < list.length; i++) {
            if (agentProvider(list[i].agent_kind) === pid)
                n++;
        }
        return n;
    }

    function costForProvider(pid) {
        for (let i = 0; i < cost.length; i++) {
            if (String(cost[i].provider).toLowerCase() === pid)
                return cost[i].cost || 0;
        }
        return 0;
    }

    function costTotal() {
        let t = 0;
        for (let i = 0; i < cost.length; i++)
            t += (cost[i].cost || 0);
        return t;
    }

    function fmtUsd(v) {
        if (typeof v !== "number")
            return "$0";
        return "$" + (v >= 100 ? Math.round(v) : (Math.round(v * 100) / 100));
    }

    function currentWindowPct(pid) {
        for (let i = 0; i < providers.length; i++) {
            if (providers[i].provider !== pid)
                continue;
            let pp = providers[i].percentages;
            if (typeof pp.weekly === "number")
                return pp.weekly;
            if (typeof pp.session === "number")
                return pp.session;
            return null;
        }
        return null;
    }

    function historySpanHours() {
        if (quotaHistory.length < 2)
            return 0;
        return (quotaHistory[quotaHistory.length - 1].t - quotaHistory[0].t) / 3600000;
    }

    function delta24h(pid) {
        if (quotaHistory.length < 2)
            return null;
        let current = currentWindowPct(pid);
        if (current === null)
            return null;
        let cutoff = Date.now() - 24 * 3600 * 1000;
        let ref = null;
        for (let i = 0; i < quotaHistory.length; i++) {
            if (quotaHistory[i].t >= cutoff) {
                ref = quotaHistory[i];
                break;
            }
        }
        if (!ref)
            ref = quotaHistory[0];
        if (!ref || !ref.p || !ref.p[pid])
            return null;
        let e = ref.p[pid];
        let refVal = (typeof e.w === "number") ? e.w : e.s;
        if (typeof refVal !== "number" || refVal === null || refVal === undefined)
            return null;
        let delta = current - refVal;
        return (delta < 0) ? Math.round(current) : Math.round(delta);
    }

    function appendSample() {
        if (stateDir === "")
            return;
        if (providers.length === 0)
            return;
        let now = Date.now();
        let sample = { t: now, p: {} };
        for (let i = 0; i < providers.length; i++) {
            let pr = providers[i];
            sample.p[pr.provider] = { s: pr.percentages.session, w: pr.percentages.weekly };
        }
        let last = quotaHistory.length > 0 ? quotaHistory[quotaHistory.length - 1] : null;
        let changed = false;
        if (last && last.p) {
            for (let k in sample.p) {
                let a = sample.p[k];
                let b = last.p[k];
                if (!b || a.s !== b.s || a.w !== b.w) {
                    changed = true;
                    break;
                }
            }
        } else {
            changed = true;
        }
        if (!last || changed || (now - last.t) >= 240000) {
            quotaHistory = quotaHistory.concat([sample]);
            if (quotaHistory.length > 1440)
                quotaHistory = quotaHistory.slice(quotaHistory.length - 1440);
            quotaHistoryFile.setText(JSON.stringify(quotaHistory));
        }
    }

    function providerIcon(id) {
        let p = providerId(id);
        let home = (typeof Quickshell !== "undefined" && Quickshell.env) ? Quickshell.env("HOME") : "";
        if (p === "codex")
            return "file://" + home + "/.local/share/icons/hicolor/scalable/apps/codex.svg";
        if (p === "opencodego")
            return "file://" + home + "/.local/share/icons/hicolor/512x512/apps/ai.opencode.desktop.png";
        if (p === "cursor")
            return "file://" + home + "/.local/share/icons/hicolor/32x32/apps/co.anysphere.cursor.png";
        return "";
    }

    function worstQuotaInfo() {
        let worst = null;
        for (let i = 0; i < providers.length; i++) {
            let p = providers[i];
            if (isDisabled(p.provider))
                continue;
            if (p.error)
                continue;
            let pp = p.percentages;
            let vals = [];
            if (typeof pp.weekly === "number")
                vals.push(pp.weekly);
            if (typeof pp.session === "number")
                vals.push(pp.session);
            if (vals.length === 0)
                continue;
            let w = vals[0];
            for (let j = 1; j < vals.length; j++)
                if (vals[j] > w)
                    w = vals[j];
            if (!worst || w > worst.pct)
                worst = { provider: p.provider, pct: Math.round(w) };
        }
        return worst;
    }

    function sessions24hCount() {
        return sessionsLast24h().length;
    }

    function providerName(id) {
        let p = providerId(id);
        if (p === "codex")
            return "Codex";
        if (p === "claude")
            return "Claude";
        if (p === "grok")
            return "Grok";
        if (p === "antigravity")
            return "Antigravity";
        if (p === "opencodego")
            return "OpenCode Go";
        if (p === "cursor")
            return "Cursor";
        return id;
    }

    // ---------- notificações (sem servidor próprio) ----------

    function sendNotification(title, body, view) {
        // DND do core: suprime o popup, mantendo o evento (pushEvent já o gravou).
        if (typeof Notifs !== "undefined" && Notifs.dnd)
            return;
        _pendingNotifyView = view || "limits";
        notifyProc.command = [
            "gdbus", "call", "--session",
            "--dest", "org.freedesktop.Notifications",
            "--object-path", "/org/freedesktop/Notifications",
            "--method", "org.freedesktop.Notifications.Notify",
            "No Limits", "0", "", title, body,
            '["default", "' + I18n.t("kodexbar.notif_open") + '"]',
            "{}", "5000"
        ];
        notifyProc.running = false;
        notifyProc.running = true;
    }

    function maybeNotify(kind, provider, text, severity) {
        if (!notifyEnabled || !text)
            return;
        if (kind !== "severity" && kind !== "error" && kind !== "reset" && kind !== "handoff" && kind !== "server")
            return;
        if (kind === "severity" && severity !== "critical")
            return;
        let key = kind + ":" + provider;
        let now = Date.now();
        let last = _notifyCooldowns[key] || 0;
        if (now - last < notifyCooldownSecs * 1000)
            return;
        _notifyCooldowns[key] = now;
        let view = (kind === "handoff" || kind === "server") ? "memory" : "limits";
        sendNotification("No Limits", text, view);
    }

    function pushEvent(kind, provider, text, severity) {
        if (!text)
            return;
        let now = Date.now();
        for (let i = 0; i < events.length && i < 5; i++) {
            let e = events[i];
            if (e.kind === kind && e.provider === provider && e.text === text && (now - e.t) < 600000)
                return;
        }
        let evt = { t: now, kind: kind, provider: provider, text: text, severity: severity || "ok" };
        events = [evt].concat(events);
        if (events.length > 100)
            events = events.slice(0, 100);
        eventsFile.setText(JSON.stringify(events));
        maybeNotify(kind, provider, text, evt.severity);
    }

    function snapshotProviders() {
        let snap = {};
        for (let i = 0; i < providers.length; i++) {
            let pr = providers[i];
            let pp = pr.percentages;
            snap[pr.provider] = {
                severity: pr.severity,
                error: pr.error,
                weekly: (typeof pp.weekly === "number") ? pp.weekly : null,
                session: (typeof pp.session === "number") ? pp.session : null
            };
        }
        return snap;
    }

    function diffQuota() {
        let next = snapshotProviders();
        let hasPrev = false;
        for (let k in _prevProviders) {
            hasPrev = true;
            break;
        }
        if (!hasPrev) {
            _prevProviders = next;
            return;
        }
        let rank = { ok: 0, warning: 1, critical: 2 };
        for (let pid in next) {
            let a = next[pid];
            let b = _prevProviders[pid];
            if (!b)
                continue;
            if (a.error && !b.error) {
                pushEvent("error", pid, I18n.t("kodexbar.evt_error", { provider: providerName(pid) }), "critical");
                continue;
            }
            if (rank[a.severity] > rank[b.severity]) {
                let pct = (a.weekly !== null) ? a.weekly : a.session;
                pushEvent("severity", pid, I18n.t("kodexbar.evt_severity", { provider: providerName(pid), pct: (pct === null ? "?" : Math.round(pct)) }), a.severity);
            }
            if (b.weekly !== null && a.weekly !== null && b.weekly - a.weekly >= 30 && b.weekly >= 50) {
                pushEvent("reset", pid, I18n.t("kodexbar.evt_reset", { provider: providerName(pid), from: Math.round(b.weekly), to: Math.round(a.weekly) }), "ok");
            } else if (b.session !== null && a.session !== null && b.session - a.session >= 30 && b.session >= 50) {
                pushEvent("reset", pid, I18n.t("kodexbar.evt_reset_session", { provider: providerName(pid), from: Math.round(b.session), to: Math.round(a.session) }), "ok");
            }
        }
        _prevProviders = next;
    }

    function diffMemory() {
        if (_prevServerUp !== null && _prevServerUp !== serverUp) {
            pushEvent("server", "", serverUp ? I18n.t("kodexbar.evt_server_up") : I18n.t("kodexbar.evt_server_down"), serverUp ? "ok" : "critical");
        }
        _prevServerUp = serverUp;

        let ids = [];
        for (let i = 0; i < handoffs.length; i++)
            ids.push(handoffs[i].id);
        if (_prevHandoffIds.length > 0 || ids.length > 0) {
            for (let i = 0; i < ids.length; i++) {
                if (_prevHandoffIds.indexOf(ids[i]) === -1) {
                    let h = handoffs[i];
                    pushEvent("handoff", agentProvider(h.agent || ""), I18n.t("kodexbar.evt_handoff", { agent: (h.agent || "?") }), "warning");
                }
            }
        }
        _prevHandoffIds = ids;

        let sids = [];
        for (let i = 0; i < sessionList.length; i++)
            sids.push(sessionList[i].session_id);
        if (_prevSessionIds.length > 0) {
            for (let i = 0; i < sessionList.length; i++) {
                let se = sessionList[i];
                if (_prevSessionIds.indexOf(se.session_id) === -1) {
                    pushEvent("session", agentProvider(se.agent_kind || ""), I18n.t("kodexbar.evt_session", { agent: providerName(agentProvider(se.agent_kind || "")) }), "ok");
                }
            }
        }
        _prevSessionIds = sids;
    }

    function fmtBytes(bytes) {
        if (!bytes || bytes <= 0)
            return "0 B";
        let units = ["B", "KB", "MB", "GB"];
        let i = 0;
        let v = bytes;
        while (v >= 1024 && i < units.length - 1) {
            v = v / 1024;
            i++;
        }
        return (v >= 10 ? Math.round(v) : (Math.round(v * 10) / 10)) + " " + units[i];
    }

    function fmtWhen(iso) {
        if (!iso)
            return "";
        let d = new Date(iso);
        if (isNaN(d.getTime()))
            return "";
        let diff = Date.now() - d.getTime();
        if (diff < 60000)
            return "agora";
        let m = diff / 60000;
        if (m < 60)
            return Math.round(m) + "min";
        let h = m / 60;
        if (h < 24)
            return Math.round(h) + "h";
        return Math.round(h / 24) + "d";
    }

    function fmtReset(iso) {
        if (!iso)
            return "";
        let d = new Date(iso);
        if (isNaN(d.getTime()))
            return "";
        let diff = d.getTime() - resetClock;
        if (diff <= 0)
            return "agora";
        let totalMinutes = Math.max(1, Math.ceil(diff / 60000));
        if (totalMinutes < 60)
            return totalMinutes + "min";
        let totalHours = Math.floor(totalMinutes / 60);
        if (totalHours < 24)
            return totalHours + "h";
        let days = Math.floor(totalHours / 24);
        let hours = totalHours % 24;
        return days + "d" + (hours > 0 ? " " + hours + "h" : "");
    }

    function webUrl() {
        let base = endpoint.replace(/\/+$/, "");
        let path = webPath.startsWith("/") ? webPath : ("/" + webPath);
        return base + path;
    }

    function logoUrl() {
        let base = endpoint.replace(/\/+$/, "");
        let path = logoPath.startsWith("/") ? logoPath : ("/" + logoPath);
        return base + path;
    }

    function openWebUi() {
        Quickshell.execDetached(["xdg-open", webUrl()]);
    }

    function ingestMemory(payload) {
        if (!payload || typeof payload !== "object")
            return;

        serverUp = payload.server === true;

        let cli = payload.cli;
        cliOk = !!(cli && typeof cli === "object");
        if (cliOk) {
            version = cli.version || "";
            bindAddress = cli.bind || "";
            let counts = cli.counts || {};
            pagesLatest = counts.pages_latest || 0;
            pagesAll = counts.pages_all || 0;
            sessions = counts.sessions || 0;
            observations = counts.observations || 0;
            let storage = cli.storage || {};
            dbBytes = storage.database_bytes || 0;
            freeBytes = storage.data_dir_free_bytes || 0;
            let providers = cli.providers || {};
            let llm = providers.llm || {};
            llmStatus = llm.status || "";
            llmProvider = llm.provider || "";
        }

        if (!serverUp) {
            projects = [];
            handoffs = [];
            recentPages = [];
            sessionList = [];
            rules = [];
            cost = [];
            pendingHandoffs = 0;
            lastObservation = "";
            diffMemory();
            memoryLastRefresh = Date.now();
            memoryLoading = false;
            return;
        }

        activeWorkspace = payload.workspace || "default";
        activeProject = payload.project || "";

        let projs = payload.projects;
        projects = Array.isArray(projs) ? projs : [];

        let overview = payload.overview || {};
        let briefing = overview.briefing || {};
        if (!cliOk) {
            let counts = briefing.counts || {};
            pagesLatest = counts.pages_latest || 0;
            pagesAll = counts.pages_all || 0;
            sessions = counts.sessions || 0;
            observations = counts.observations || 0;
        }
        pendingHandoffs = briefing.pending_handoff_count || 0;
        lastObservation = briefing.last_observation_at || "";

        let hs = payload.handoffs;
        handoffs = Array.isArray(hs) ? hs : [];

        let rp = payload.recent;
        if (Array.isArray(rp))
            recentPages = rp;
        else if (rp && Array.isArray(rp.pages))
            recentPages = rp.pages;
        else
            recentPages = [];

        let rr = briefing.rules;
        rules = Array.isArray(rr) ? rr : [];

        let ss = payload.sessions;
        sessionList = Array.isArray(ss) ? ss : [];
        let cc = payload.cost;
        cost = Array.isArray(cc) ? cc : [];

        diffMemory();
        memoryLastRefresh = Date.now();
        memoryLoading = false;
    }

    // ---------- processes ----------

    FileView {
        id: eventsFile
        path: root.stateDir ? (root.stateDir + "/events.json") : ""
        watchChanges: false
    }

    Process {
        id: eventsLoadProc
        command: ["cat", root.stateDir ? (root.stateDir + "/events.json") : "/nonexistent"]
        stdout: StdioCollector {
            id: eventsOut
            onStreamFinished: {
                try {
                    let d = JSON.parse(eventsOut.text.trim());
                    if (Array.isArray(d))
                        root.events = d;
                } catch (e) {}
            }
        }
    }

    FileView {
        id: quotaHistoryFile
        path: root.stateDir ? (root.stateDir + "/quota-history.json") : ""
        watchChanges: false
    }

    Process {
        id: historyLoadProc
        command: ["cat", root.stateDir ? (root.stateDir + "/quota-history.json") : "/nonexistent"]
        stdout: StdioCollector {
            id: historyOut
            onStreamFinished: {
                try {
                    let d = JSON.parse(historyOut.text.trim());
                    if (Array.isArray(d))
                        root.quotaHistory = d;
                } catch (e) {}
            }
        }
    }

    Process {
        id: quotaProc
        command: ["bash", "-c", "kodexbar-quotas usage --format json --provider all"]
        stdout: StdioCollector {
            id: quotaOut
            onStreamFinished: {
                try {
                    let data = JSON.parse(quotaOut.text.trim());
                    if (!Array.isArray(data))
                        throw new Error("not a list");
                    root.entries = data;
                    root.quotaError = false;
                    root.rebuildQuota();
                    root.diffQuota();
                    root.appendSample();
                } catch (e) {
                    root.entries = [];
                    root.cards = [];
                    root.providers = [];
                    root.quotaError = true;
                }
                root.quotaLastRefresh = Date.now();
                root.quotaLoading = false;
            }
        }
        onExited: (code) => {
            if (root.quotaLoading) {
                root.quotaLoading = false;
                root.quotaLastRefresh = Date.now();
            }
        }
    }

    Process {
        id: memoryProc
        command: [
            "bash",
            Caching.serpantinumDir + "/scripts/ai-memory-probe.sh",
            root.endpoint,
            root.workspace,
            root.project
        ]
        stdout: StdioCollector {
            id: memoryOut
            onStreamFinished: {
                try {
                    let payload = JSON.parse(memoryOut.text.trim());
                    root.ingestMemory(payload);
                } catch (e) {
                    root.serverUp = false;
                    root.memoryLoading = false;
                    root.memoryLastRefresh = Date.now();
                }
            }
        }
        onExited: (code) => {
            if (root.memoryLoading) {
                root.memoryLoading = false;
                root.memoryLastRefresh = Date.now();
            }
        }
    }

    Process {
        id: notifyProc
        command: []
        stdout: StdioCollector {
            id: notifyOut
            onStreamFinished: {
                let m = notifyOut.text.match(/uint32\s+(\d+)/);
                if (!m)
                    return;
                let ids = root._notifyIds.slice();
                ids.push({ id: parseInt(m[1], 10), view: root._pendingNotifyView });
                if (ids.length > 8)
                    ids = ids.slice(ids.length - 8);
                root._notifyIds = ids;
            }
        }
    }

    // Monitor persistente do bus para a ação "Abrir". O core é dono do
    // servidor de notificações; aqui só escutamos ActionInvoked e abrimos a view.
    Process {
        id: actionMonitor
        command: ["gdbus", "monitor", "--session", "--dest", "org.freedesktop.Notifications"]
        running: true
        stdout: SplitParser {
            onRead: function(line) {
                let m = line.match(/ActionInvoked\s*\(uint32\s+(\d+),\s*'([^']*)'\)/);
                if (!m)
                    return;
                if (m[2] !== "default")
                    return;
                let id = parseInt(m[1], 10);
                let entry = null;
                for (let i = 0; i < root._notifyIds.length; i++) {
                    if (root._notifyIds[i].id === id)
                        entry = root._notifyIds[i];
                }
                if (!entry)
                    return;
                root.show(entry.view || "limits");
            }
        }
    }

    Timer {
        interval: root.refreshInterval * 1000
        repeat: true
        running: root.enabled
        onTriggered: root.refreshQuotas()
    }

    Timer {
        interval: root.refreshInterval * 1000
        repeat: true
        running: root.memoryEnabled
        onTriggered: root.refreshMemory()
    }

    Timer {
        interval: 30000
        repeat: true
        running: true
        onTriggered: root.resetClock = Date.now()
    }

    Component.onCompleted: {
        historyLoadProc.running = true;
        eventsLoadProc.running = true;
        if (root.enabled)
            root.refreshQuotas();
        if (root.memoryEnabled)
            root.refreshMemory();
    }
}
