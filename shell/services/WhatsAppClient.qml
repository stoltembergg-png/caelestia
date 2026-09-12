// WhatsAppClient — ponte IPC do caelestia-whatsapp.
//
// Fala exclusivamente o protocolo documentado em docs/IPC.md (NDJSON sobre Unix
// domain socket). NÃO contém lógica do protocolo WhatsApp: apenas serializa
// requests, correlaciona responses por `id`, trata eventos push e mantém os
// modelos de UI.
//
// Regras de segurança/contrato respeitadas:
//   * sem HTTP/TCP/WebEngine — só Quickshell.Io.Socket;
//   * credenciais nunca passam por aqui (a sessão vive no SQLite do daemon);
//   * IDs e timestamps de 64 bits são tratados como string (precisão do JS);
//   * reconexão com backoff exponencial + jitter, fila pré-conexão e heartbeat.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.extras.whatsapp

Singleton {
    id: root

    // ------------------------------------------------------------------ //
    // Estado público
    // ------------------------------------------------------------------ //
    // needs_pairing | connecting | connected | disconnected | logged_out |
    // banned | outdated | stream_replaced | unknown
    property string authState: "unknown"
    property string connectionState: "disconnected"
    property bool loggedIn: false
    // Fontes independentes de "pareado": o daemon pode anunciar por
    // `auth.connected`, por `connection.updated {state:"connected"}` ou pelo
    // snapshot de `status`, e qualquer uma delas basta para sair do LoginView.
    readonly property bool paired: root.loggedIn || root.authState === "connected" || root.connectionState === "connected"
    property string pushName: ""
    property string accountJid: ""
    property string lastError: ""

    // QR pronto para o Image: data URI `data:image/png;base64,...`.
    property string qrPng: ""
    property int qrTimeout: 0

    property int unreadCount: 0

    // Conversa aberta no momento (jid + nome amigável para o header).
    property string currentChat: ""
    property string currentChatName: ""
    property string currentChatAvatar: ""

    // Alvo de resposta (faixa de citação no composer).
    property string replyToId: ""
    property string replyToName: ""
    property string replyToText: ""
    property bool replyToFromMe: false

    // Lista de conversas (chats.list / chat.updated).
    readonly property alias chats: chatsModel
    // Mensagens da conversa aberta, em ordem cronológica (antiga -> recente).
    readonly property alias messages: messagesModel

    // Sinais de conveniência para a UI.
    signal messageAppended(string jid)
    signal chatsRefreshed()

    // Sobe o notifier junto com o cliente (o monitor D-Bus precisa estar vivo
    // antes de surgir a primeira notificação).
    Component.onCompleted: WhatsAppNotifier.warmup()

    // ------------------------------------------------------------------ //
    // Socket
    // ------------------------------------------------------------------ //
    readonly property string socketPath: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/caelestia-whatsapp.sock"
    property bool socketConnected: false

    ListModel {
        id: chatsModel
    }

    ListModel {
        id: messagesModel
    }

    // Objeto Socket mantido sob um Loader para permitir recriá-lo (o
    // Quickshell.Io.Socket não limpa o QLocalSocket quando a 1ª tentativa de
    // conexão falha — recriar garante um connect novo e limpo).
    readonly property var socket: sockLoader.item
    // Referência viva ao Socket em uso, capturada pelo próprio componente
    // (id `sock`). `sockLoader.item` só é atribuído quando a criação do objeto
    // termina, e o `onConnectedChanged` de um socket local pode disparar
    // durante a construção; sem esta referência o primeiro `status` ficava
    // preso na fila (nada era escrito, nenhuma resposta chegava e o cliente
    // permanecia "não pareado" para sempre).
    property var _io: null

    Loader {
        id: sockLoader

        active: true
        asynchronous: false
        sourceComponent: Socket {
            id: sock

            path: root.socketPath
            connected: true

            parser: SplitParser {
                onRead: data => root._onLine(data)
            }

            onConnectedChanged: root._onSocketConnectedChanged(sock, connected)
            // qmllint disable signal-handler-parameters
            // O enum QLocalSocket::LocalSocketError não está no qmltypes; o
            // parâmetro é válido em runtime.
            onError: error => root._onSocketError(error)
            // qmllint enable signal-handler-parameters
        }
    }

    // Recriação do socket após backoff.
    Timer {
        id: recreateTimer

        interval: 16
        repeat: false
        onTriggered: {
            if (!sockLoader.active)
                sockLoader.active = true;
        }
    }

    // Backoff exponencial com jitter.
    Timer {
        id: reconnectTimer

        interval: 500
        repeat: false
        onTriggered: root._attemptReconnect()
    }

    // Heartbeat: detecta conexão morta e mantém o daemon acordado.
    Timer {
        id: heartbeat

        interval: 25000
        repeat: true
        running: root.socketConnected
        onTriggered: {
            if (Date.now() - root._lastRxAt > 45000) {
                root._forceReconnect();
                return;
            }
            root._send("ping", null, function (res, err) {
                if (err)
                    root._forceReconnect();
            }, 6000);
        }
    }

    // Watchdog de timeouts de request.
    Timer {
        id: watchdog

        interval: 1000
        repeat: true
        running: root._pendingCount > 0
        onTriggered: root._expireRequests()
    }

    // Watchdog do QR: o `auth.start` respondeu, mas nenhum `auth.qr` chegou.
    // Sem isso a UI ficava presa em "Gerando código…" para sempre quando o
    // canal de QR morria em silêncio (timeout/cancel/erro do daemon).
    Timer {
        id: loginWatch

        interval: 20000
        repeat: false
        onTriggered: {
            if (root.loggedIn || root.authState === "connected" || root.qrPng.length > 0)
                return;
            root.lastError = "tempo esgotado ao gerar o código; tente de novo";
            root.authState = "needs_pairing";
        }
    }

    // Bombeia um pedido de avatar por vez (backoff curto) para não inundar o
    // daemon com 47 downloads ao mesmo tempo.
    Timer {
        id: avatarPump

        interval: 350
        repeat: false
        onTriggered: root._pumpAvatar()
    }

    // ------------------------------------------------------------------ //
    // Máquina de estado / correlação
    // ------------------------------------------------------------------ //
    property int _nextId: 0
    property int _tempSeq: 0
    readonly property var _pending: ({})
    readonly property var _queue: []
    property int _pendingCount: 0
    property int _reconnectAttempts: 0
    property double _lastRxAt: 0
    readonly property int _requestTimeout: 15000
    readonly property int _maxQueue: 128
    property bool _shuttingDown: false
    readonly property var _avatarRequested: ({})
    readonly property var _avatarQueue: []

    function _syncPendingCount(): void {
        root._pendingCount = Object.keys(root._pending).length;
    }

    function _connected(): bool {
        return root._io !== null && root._io !== undefined && root.socketConnected;
    }

    // Extrai a mensagem de erro do envelope de erro do daemon.
    function _errorMessage(err): string {
        if (!err)
            return "";
        return String(err.message || err.code || err);
    }

    function _send(method, params, callback, timeout) {
        const entry = {
            "method": String(method),
            "params": params === undefined ? null : params,
            "callback": callback || null,
            "timeout": timeout || root._requestTimeout
        };
        if (!root._connected()) {
            if (root._queue.length < root._maxQueue)
                root._queue.push(entry);
            return;
        }
        root._dispatch(entry);
    }

    function _dispatch(entry) {
        const id = ++root._nextId;
        root._pending[id] = {
            "callback": entry.callback,
            "expires": Date.now() + entry.timeout
        };
        root._syncPendingCount();
        const payload = {
            "id": id,
            "method": entry.method
        };
        if (entry.params !== null && entry.params !== undefined)
            payload.params = entry.params;
        root._io.write(JSON.stringify(payload) + "\n");
        root._io.flush();
    }

    function _flushQueue() {
        const queued = root._queue.splice(0, root._queue.length);
        for (let i = 0; i < queued.length; i++)
            root._dispatch(queued[i]);
    }

    function _expireRequests() {
        const now = Date.now();
        for (const key of Object.keys(root._pending)) {
            const p = root._pending[key];
            if (p.expires <= now) {
                delete root._pending[key];
                if (p.callback)
                    p.callback(null, {
                        "code": "timeout",
                        "message": "request timed out"
                    });
            }
        }
        root._syncPendingCount();
    }

    function _failPending(code, message) {
        for (const key of Object.keys(root._pending)) {
            const p = root._pending[key];
            delete root._pending[key];
            if (p.callback)
                p.callback(null, {
                    "code": code,
                    "message": message
                });
        }
        root._syncPendingCount();
    }

    // ------------------------------------------------------------------ //
    // Ciclo de vida da conexão
    // ------------------------------------------------------------------ //
    function _onSocketConnectedChanged(sock, connected) {
        root._io = connected ? sock : null;
        root.socketConnected = connected;
        if (connected)
            root._onConnected();
        else if (!root._shuttingDown)
            root._onDisconnected();
    }

    function _onSocketError(error) {
        // `error` é QLocalSocket::LocalSocketError; só registamos e agendamos
        // reconexão. A conexão recusada (daemon parado) passa por aqui.
        root.connectionState = "disconnected";
        if (!root._shuttingDown)
            root._scheduleReconnect();
    }

    function _onConnected() {
        root._reconnectAttempts = 0;
        reconnectTimer.stop();
        root._lastRxAt = Date.now();
        // O socket subiu, mas o estado do WhatsApp ainda não é conhecido: NÃO
        // marcar "connected" aqui (senão o LoginView some antes do pareamento).
        // `status`/eventos trazem o estado real do daemon.
        if (!root.paired)
            root.connectionState = "connecting";
        if (root.authState === "unknown" || root.authState === "disconnected")
            root.authState = "connecting";

        root._flushQueue();
        root._bootstrap();
    }

    function _onDisconnected() {
        root.socketConnected = false;
        root.connectionState = "disconnected";
        root._failPending("disconnected", "socket disconnected");
        root._scheduleReconnect();
    }

    function _scheduleReconnect() {
        if (reconnectTimer.running)
            return;
        const attempt = root._reconnectAttempts++;
        const base = Math.min(30000, 500 * Math.pow(2, attempt));
        const jitter = 0.5 + Math.random() * 0.5;
        reconnectTimer.interval = Math.round(base * jitter);
        reconnectTimer.restart();
    }

    function _attemptReconnect() {
        // Recria o Socket para garantir um QLocalSocket novo mesmo quando a
        // tentativa anterior falhou antes de conectar.
        root._failPending("disconnected", "reconnecting");
        root.socketConnected = false;
        root._io = null;
        sockLoader.active = false;
        recreateTimer.restart();
    }

    function _forceReconnect() {
        reconnectTimer.stop();
        root._scheduleReconnect();
    }

    // Snapshot inicial: status traz conexão + auth.
    function _bootstrap() {
        root._send("status", null, function (res, err) {
            if (err || !res)
                return;
            const conn = res.connection ? String(res.connection.state || "") : "";
            const auth = res.auth || ({});
            const authSt = String(auth.state || "");
            if (conn)
                root.connectionState = conn;
            const isPaired = auth.logged_in === true || auth.logged_in === 1 || String(auth.logged_in) === "true" || authSt === "connected" || conn === "connected";
            if (isPaired) {
                root._markPaired(auth.push_name, auth.jid);
            } else {
                root.loggedIn = false;
                if (authSt)
                    root.authState = authSt;
                root.pushName = String(auth.push_name || "");
                root.accountJid = String(auth.jid || "");
            }
        });
    }

    // Ponto único de "pareado": usado por `auth.connected`, por
    // `connection.updated {state:"connected"}` e pelo snapshot de `status`.
    // Limpa QR/erro, esconde o LoginView (via `paired`) e recarrega os chats.
    function _markPaired(pushName, jid) {
        const wasPaired = root.loggedIn;
        root.loggedIn = true;
        root.authState = "connected";
        root.connectionState = "connected";
        root.qrPng = "";
        root.lastError = "";
        loginWatch.stop();
        if (pushName)
            root.pushName = String(pushName);
        if (jid)
            root.accountJid = String(jid);
        if (!wasPaired || chatsModel.count === 0)
            root.refreshChats();
    }

    // ------------------------------------------------------------------ //
    // Recebimento NDJSON
    // ------------------------------------------------------------------ //
    function _onLine(line) {
        const text = String(line || "").trim();
        if (!text.length)
            return;
        root._lastRxAt = Date.now();

        let msg = null;
        try {
            msg = JSON.parse(text);
        } catch (e) {
            return;
        }
        if (!msg || typeof msg !== "object")
            return;

        if (msg.event !== undefined && msg.event !== null) {
            root._handleEvent(String(msg.event), msg.data || ({}));
            return;
        }

        if (msg.id === undefined || msg.id === null)
            return;
        const p = root._pending[msg.id];
        if (!p)
            return;
        delete root._pending[msg.id];
        root._syncPendingCount();
        if (!p.callback)
            return;
        if (msg.error)
            p.callback(null, msg.error);
        else
            p.callback(msg.result === undefined ? null : msg.result, null);
    }

    function _handleEvent(name, data) {
        if (name === "auth.qr") {
            const b64 = data.png_base64 || data.pngBase64 || data.png || data.base64 || "";
            if (b64) {
                const s = String(b64);
                root.qrPng = s.startsWith("data:") ? s : "data:image/png;base64," + s;
            }
            root.qrTimeout = Number(data.timeout || 0);
            root.lastError = "";
            loginWatch.stop();
            if (!root.loggedIn && root.authState !== "connected")
                root.authState = "connecting";
        } else if (name === "auth.connected") {
            root._markPaired(data.push_name, data.jid);
        } else if (name === "auth.disconnected") {
            root.loggedIn = false;
            root.authState = "disconnected";
            root.qrPng = "";
            root.lastError = String(data.reason || "");
            loginWatch.stop();
        } else if (name === "auth.error") {
            root.lastError = String(data.message || "auth error");
            // Um erro de pareamento encerra a tentativa: sai de "connecting"
            // para a UI mostrar o erro com a ação de tentar novamente.
            root.qrPng = "";
            loginWatch.stop();
            if (!root.loggedIn && root.authState !== "connected")
                root.authState = "needs_pairing";
        } else if (name === "connection.updated") {
            const st = String(data.state || "disconnected");
            root.connectionState = st;
            if (st === "connected") {
                // "connected" no daemon = sessão pareada ligada ao WhatsApp.
                root._markPaired();
            } else if (!root.paired) {
                if (st === "needs_pairing" || st === "logged_out")
                    root.authState = st;
                else if (st === "connecting")
                    root.authState = "connecting";
            }
        } else if (name === "message.received") {
            root._onMessageReceived(data);
        } else if (name === "message.updated" || name === "message.deleted") {
            root._onMessageUpdated(data);
        } else if (name === "receipt.updated") {
            root._onReceiptUpdated(data);
        } else if (name === "media.upload") {
            root._onMediaUpload(data);
        } else if (name === "chat.updated") {
            root._upsertChat(data.chat || data, true);
        }
    }

    // ------------------------------------------------------------------ //
    // Conversas
    // ------------------------------------------------------------------ //
    function _shortTail(local) {
        const s = String(local || "");
        return s.length > 4 ? s.slice(-4) : s;
    }

    // Nome exibível mesmo quando o daemon ainda não resolveu o contato:
    // nunca devolve o JID/LID cru com domínio. Para LID usa "Contato NNNN";
    // para telefone usa "+<número>"; grupo vira "Grupo".
    function _readableName(name, jid, kind) {
        const jidStr = String(jid || "");
        const raw = String(name || "").trim();
        const at = jidStr.indexOf("@");
        const local = (at >= 0 ? jidStr.substring(0, at) : jidStr).split(":")[0];
        const isGroup = String(kind || "") === "group" || jidStr.indexOf("@g.us") >= 0;
        const isLid = jidStr.indexOf("@lid") >= 0;
        const rawNumeric = /^[0-9]{6,}$/.test(raw);
        // O nome é genérico se vazio, igual ao JID/local, ou um número cru
        // (LID não resolvido ou telefone sem contato).
        const generic = raw.length === 0 || raw === jidStr || raw === local || (isLid && rawNumeric) || (rawNumeric && raw.length >= 12 && raw !== local);
        if (!generic)
            return raw;
        if (isGroup)
            return "Grupo";
        const num = rawNumeric ? raw : local;
        if (isLid)
            return "Contato " + root._shortTail(num);
        if (/^[0-9]{6,}$/.test(num))
            return "+" + num;
        return "Contato";
    }

    function _field(c, base, key) {
        if (c && c[key] !== undefined && c[key] !== null)
            return c[key];
        if (base && base[key] !== undefined && base[key] !== null)
            return base[key];
        return undefined;
    }

    // Converte placeholders crus do tipo "[unknown]"/"[Image]"/"[audio]" em
    // rótulos amigáveis. Texto normal passa intacto.
    function _normalizePreview(text) {
        const s = String(text || "").trim();
        if (!s.length)
            return "";
        const m = s.match(/^\[([a-zA-Z]+)\]$/);
        if (!m)
            return s;
        const labels = {
            "image": "Foto",
            "photo": "Foto",
            "video": "Vídeo",
            "audio": "Áudio",
            "voice": "Áudio",
            "document": "Documento",
            "sticker": "Figurinha",
            "location": "Localização",
            "contact": "Contato",
            "reaction": "Reação",
            "unknown": "Mensagem",
            "message": "Mensagem"
        };
        return labels[m[1].toLowerCase()] || "Mensagem";
    }

    function _chatRow(c, base) {
        const jid = String(root._field(c, base, "jid") || "");
        const kind = String(root._field(c, base, "kind") || "dm");
        let last = root._field(c, base, "lastMessage");
        if (last === undefined)
            last = root._field(c, base, "last_message");
        if (last === undefined)
            last = root._field(c, base, "lastPreview");
        let unread = root._field(c, base, "unread");
        if (unread === undefined)
            unread = root._field(c, base, "unread_count");
        const avatar = root._field(c, base, "avatar");
        return {
            "jid": jid,
            "kind": kind,
            "name": root._readableName(root._field(c, base, "name"), jid, kind),
            "lastMessage": root._normalizePreview(last),
            "timestamp": String(root._field(c, base, "timestamp") || ""),
            "unread": Number(unread === undefined ? 0 : unread),
            "avatar": avatar ? String(avatar) : ""
        };
    }

    // ------------------------------------------------------------------ //
    // Avatares (download em background, uma vez por jid)
    // ------------------------------------------------------------------ //
    function requestAvatar(jid) {
        const j = String(jid || "");
        if (!j.length || root._avatarRequested[j])
            return;
        root._avatarRequested[j] = true;
        root._avatarQueue.push(j);
        if (!avatarPump.running)
            avatarPump.start();
    }

    function _pumpAvatar() {
        if (!root._avatarQueue.length)
            return;
        const jid = root._avatarQueue.shift();
        root._send("avatars.download", {
            "jid": jid
        }, function (res, err) {
            if (!err && res && res.path)
                root._applyAvatar(jid, res.path);
            if (root._avatarQueue.length)
                avatarPump.start();
        });
    }

    function _applyAvatar(jid, path) {
        const j = String(jid || "");
        const p = String(path || "");
        if (!j)
            return;
        const idx = root._chatIndex(j);
        if (idx >= 0)
            chatsModel.setProperty(idx, "avatar", p);
        if (j === root.currentChat)
            root.currentChatAvatar = p;
    }

    function _chatIndex(jid) {
        for (let i = 0; i < chatsModel.count; i++) {
            if (chatsModel.get(i).jid === jid)
                return i;
        }
        return -1;
    }

    function _chatName(jid) {
        const idx = root._chatIndex(jid);
        if (idx >= 0)
            return String(chatsModel.get(idx).name || jid);
        return root._readableName("", jid, "");
    }

    function _recountUnread() {
        let total = 0;
        for (let i = 0; i < chatsModel.count; i++)
            total += Number(chatsModel.get(i).unread || 0);
        root.unreadCount = total;
    }

    // O pseudo-chat de Status não é uma conversa.
    function _isSystemChat(jid) {
        return String(jid || "") === "status@broadcast";
    }

    function _upsertChat(c, moveTop) {
        if (!c || !c.jid || root._isSystemChat(c.jid))
            return;
        const idx0 = root._chatIndex(String(c.jid));
        const base = idx0 >= 0 ? chatsModel.get(idx0) : null;
        const row = root._chatRow(c, base);
        if (!row.jid)
            return;
        const idx = root._chatIndex(row.jid);
        if (idx < 0) {
            chatsModel.append(row);
        } else {
            chatsModel.set(idx, row);
        }
        const cur = root._chatIndex(row.jid);
        if (moveTop && cur > 0)
            chatsModel.move(cur, 0, 1);
        root._recountUnread();
        if (row.jid === root.currentChat) {
            root.currentChatName = row.name;
            if (row.avatar.length)
                root.currentChatAvatar = row.avatar;
        }
    }

    function _bumpChatPreview(jid, preview, timestamp, incrementUnread) {
        const idx = root._chatIndex(jid);
        if (idx < 0) {
            root.refreshChats();
            return;
        }
        const c = chatsModel.get(idx);
        const row = {
            "jid": c.jid,
            "kind": c.kind,
            "name": c.name,
            "lastMessage": String(preview || ""),
            "timestamp": String(timestamp || ""),
            "unread": incrementUnread ? Number(c.unread || 0) + 1 : Number(c.unread || 0),
            "avatar": String(c.avatar || "")
        };
        chatsModel.set(idx, row);
        if (idx > 0)
            chatsModel.move(idx, 0, 1);
        root._recountUnread();
    }

    function refreshChats() {
        root._send("chats.list", {
            "limit": 100
        }, function (res, err) {
            if (err || !Array.isArray(res))
                return;
            const list = res.slice().sort(function (a, b) {
                return Number(b.timestamp || 0) - Number(a.timestamp || 0);
            });
            chatsModel.clear();
            for (let i = 0; i < list.length; i++) {
                if (root._isSystemChat(list[i].jid))
                    continue;
                chatsModel.append(root._chatRow(list[i]));
                if (!list[i].avatar)
                    root.requestAvatar(String(list[i].jid || ""));
            }
            root._recountUnread();
            root.chatsRefreshed();
            if (root.currentChat) {
                root.currentChatName = root._chatName(root.currentChat);
                const ci = root._chatIndex(root.currentChat);
                if (ci >= 0)
                    root.currentChatAvatar = String(chatsModel.get(ci).avatar || "");
            }
        });
    }

    function openChat(jid) {
        if (!jid)
            return;
        const id = String(jid);
        root.currentChat = id;
        root.currentChatName = root._chatName(id);
        const ci = root._chatIndex(id);
        root.currentChatAvatar = ci >= 0 ? String(chatsModel.get(ci).avatar || "") : "";
        if (!root.currentChatAvatar.length)
            root.requestAvatar(id);
        root.clearReply();
        messagesModel.clear();
        root._send("chat.messages", {
            "jid": id,
            "limit": 60
        }, function (res, err) {
            if (err || !Array.isArray(res))
                return;
            const list = res.slice().reverse(); // daemon devolve recentes primeiro
            for (let i = 0; i < list.length; i++)
                root._appendMessageIfNew(list[i]);
            root.messageAppended(id);
        });
        root.markRead();
    }

    function closeChat() {
        root.currentChat = "";
        root.currentChatName = "";
        root.currentChatAvatar = "";
        root.clearReply();
        messagesModel.clear();
    }

    // ------------------------------------------------------------------ //
    // Mensagens
    // ------------------------------------------------------------------ //
    function _mediaObject(m) {
        const md = m && m.media ? m.media : null;
        if (!md || typeof md !== "object")
            return null;
        return {
            "kind": String(md.kind || ""),
            "mime": String(md.mime || ""),
            "size": Number(md.size || 0),
            "width": Number(md.width || 0),
            "height": Number(md.height || 0),
            "downloaded": md.downloaded === true || Boolean(md.path),
            "thumb": String(md.thumb || ""),
            "path": String(md.path || ""),
            "duration": Number(md.duration || 0)
        };
    }

    function _reactionsArray(r) {
        if (!Array.isArray(r))
            return [];
        const out = [];
        for (let i = 0; i < r.length; i++) {
            const e = r[i];
            if (!e)
                continue;
            const emoji = String(e.emoji || e.reaction || "");
            if (!emoji.length)
                continue;
            out.push({
                "sender": String(e.sender || ""),
                "emoji": emoji,
                "fromMe": e.from_me === true || e.fromMe === true
            });
        }
        return out;
    }

    // O ListModel não preserva arrays como role, então as reações viajam como
    // string JSON e são parseadas pela UI/consumidores.
    function reactionsOf(json) {
        try {
            const parsed = JSON.parse(String(json || "[]"));
            return Array.isArray(parsed) ? parsed : [];
        } catch (e) {
            return [];
        }
    }

    // Citação: usa o payload se vier, senão procura a mensagem carregada.
    function _quotedInfo(m) {
        if (m.quotedText !== undefined)
            return {
                "text": String(m.quotedText || ""),
                "fromMe": m.quotedFromMe === true
            };
        const q = m.quoted || m.quote;
        if (q && typeof q === "object")
            return {
                "text": String(q.text || root._previewFor(q)),
                "fromMe": q.fromMe === true || q.from_me === true
            };
        const qid = String(m.quotedId || "");
        if (!qid.length)
            return {
                "text": "",
                "fromMe": false
            };
        const idx = root._messageIndex(qid);
        if (idx >= 0) {
            const qm = messagesModel.get(idx);
            return {
                "text": root._previewFor(qm),
                "fromMe": qm.fromMe === true
            };
        }
        return {
            "text": "",
            "fromMe": false
        };
    }

    function _messageRow(m) {
        const quoted = root._quotedInfo(m);
        return {
            "messageId": String(m.id || ""),
            "chat": String(m.chat || ""),
            "sender": String(m.sender || ""),
            "fromMe": m.fromMe === true,
            "timestamp": String(m.timestamp || ""),
            "type": String(m.type || "text"),
            "text": String(m.text || ""),
            "quotedId": String(m.quotedId || ""),
            "quotedText": quoted.text,
            "quotedFromMe": quoted.fromMe,
            "edited": m.edited === true,
            "deleted": m.deleted === true,
            "status": String(m.status || ""),
            // Nunca usar null: o ListModel não cria a role quando o valor é null
            // ("Adding an object with a null member does not create a role"),
            // o que derruba os delegates (required property sem valor).
            "media": root._mediaObject(m) || ({}),
            "reactions": JSON.stringify(root._reactionsArray(m.reactions)),
            // Envio otimista de mídia: preview local + estado de upload.
            "localPath": String(m.localPath || ""),
            "upload": m.upload || false
        };
    }

    function _messageIndex(id) {
        if (!id)
            return -1;
        for (let i = 0; i < messagesModel.count; i++) {
            if (messagesModel.get(i).messageId === id)
                return i;
        }
        return -1;
    }

    function _appendMessageIfNew(m) {
        const row = root._messageRow(m);
        const idx = root._messageIndex(row.messageId);
        if (idx >= 0) {
            messagesModel.set(idx, row);
            return;
        }
        messagesModel.append(row);
    }

    function _previewFor(m) {
        if (m.deleted)
            return "mensagem apagada";
        if (m.type && m.type !== "text" && m.type !== "protocol") {
            const labels = {
                "image": "Foto",
                "video": "Vídeo",
                "audio": "Áudio",
                "document": "Documento",
                "sticker": "Figurinha",
                "location": "Localização",
                "contact": "Contato",
                "reaction": "Reação",
                "unknown": "Mensagem"
            };
            return labels[m.type] || "Mensagem";
        }
        return String(m.text || "");
    }

    function _onMessageReceived(data) {
        const msg = data.message || data;
        const jid = String(data.chat || msg.chat || "");
        if (!msg || !jid)
            return;
        root._appendMessageIfNew(msg);

        const fromMe = msg.fromMe === true;
        root._bumpChatPreview(jid, root._previewFor(msg), msg.timestamp, !fromMe);

        // Notificação de entrada: o notifier decide se suprime (drawer aberto,
        // DND, preferência desligada, cooldown por conversa).
        if (!fromMe)
            WhatsAppNotifier.notify(jid, root._chatName(jid), root._previewFor(msg));

        if (jid === root.currentChat) {
            if (!fromMe)
                root.markRead();
            root.messageAppended(jid);
        }
    }

    function _onMessageUpdated(data) {
        // Atualização só de reação: {chat, id, reaction}
        if (data.reaction !== undefined || (data.emoji !== undefined && (data.id !== undefined || data.message_id !== undefined))) {
            root._applyReaction(data);
            return;
        }
        const msg = data.message || data;
        if (!msg)
            return;
        const row = root._messageRow(msg);
        const idx = root._messageIndex(row.messageId);
        if (idx >= 0)
            messagesModel.set(idx, row);
        else if (row.messageId)
            messagesModel.append(row);
    }

    function _applyReaction(data) {
        const id = String(data.id || data.message_id || (data.message && data.message.id) || "");
        if (!id.length)
            return;
        const idx = root._messageIndex(id);
        if (idx < 0)
            return;
        const r = data.reaction;
        const sender = String((r && r.sender) || data.sender || "");
        const emoji = String((r && (r.emoji || r.reaction)) || data.emoji || "");
        const fromMe = (r && (r.from_me === true || r.fromMe === true)) || data.from_me === true;
        const list = root.reactionsOf(messagesModel.get(idx).reactions).slice();
        for (let i = list.length - 1; i >= 0; i--) {
            if (String(list[i].sender) === sender)
                list.splice(i, 1);
        }
        if (emoji.length)
            list.push({
                "sender": sender,
                "emoji": emoji,
                "fromMe": fromMe
            });
        messagesModel.setProperty(idx, "reactions", JSON.stringify(list));
    }

    function _onReceiptUpdated(data) {
        const id = String(data.id || data.message_id || (data.message && data.message.id) || "");
        const status = String(data.status || (data.message && data.message.status) || "");
        if (!id || !status)
            return;
        const idx = root._messageIndex(id);
        if (idx >= 0)
            messagesModel.setProperty(idx, "status", status);
    }

    // ------------------------------------------------------------------ //
    // Resposta / reações / mídia
    // ------------------------------------------------------------------ //
    function setReplyTarget(id, name, text, fromMe) {
        root.replyToId = String(id || "");
        root.replyToName = String(name || "");
        root.replyToText = String(text || "");
        root.replyToFromMe = fromMe === true;
    }

    function beginReply(chat, id, fromMe) {
        const mid = String(id || "");
        if (!mid.length)
            return;
        const idx = root._messageIndex(mid);
        const row = idx >= 0 ? messagesModel.get(idx) : null;
        root.setReplyTarget(mid, root._chatName(chat), row ? root._previewFor(row) : "", fromMe === true);
    }

    function clearReply() {
        root.replyToId = "";
        root.replyToName = "";
        root.replyToText = "";
        root.replyToFromMe = false;
    }

    // Nota: emoji vazio remove a reação (contrato do daemon).
    function react(chat, id, emoji) {
        const jid = String(chat || root.currentChat);
        const mid = String(id || "");
        const em = String(emoji || "");
        if (!jid.length || !mid.length)
            return;
        const idx = root._messageIndex(mid);
        if (idx >= 0) {
            const list = root.reactionsOf(messagesModel.get(idx).reactions).slice();
            for (let i = list.length - 1; i >= 0; i--) {
                if (String(list[i].sender) === root.accountJid)
                    list.splice(i, 1);
            }
            if (em.length) {
                const me = {
                    "sender": root.accountJid,
                    "emoji": em,
                    "fromMe": true
                };
                list.push(me);
            }
            messagesModel.setProperty(idx, "reactions", JSON.stringify(list));
        }
        root._send("message.react", {
            "chat": jid,
            "id": mid,
            "emoji": em
        }, function (res, err) {
            if (err)
                root.lastError = root._errorMessage(err);
        });
    }

    function myReaction(chat, id) {
        const idx = root._messageIndex(String(id || ""));
        if (idx < 0)
            return "";
        const list = root.reactionsOf(messagesModel.get(idx).reactions);
        for (let i = 0; i < list.length; i++) {
            if (list[i].fromMe)
                return String(list[i].emoji || "");
        }
        return "";
    }

    function toggleReaction(chat, id, emoji) {
        const mine = root.myReaction(chat, id);
        root.react(chat, id, mine === String(emoji) ? "" : String(emoji));
    }

    function openPath(path) {
        const p = String(path || "");
        if (!p.length)
            return;
        Quickshell.execDetached(["xdg-open", p]);
    }

    // Baixa (ou reaproveita o cache) e devolve o objeto media via callback.
    function downloadMedia(chat, id, callback) {
        const jid = String(chat || root.currentChat);
        const mid = String(id || "");
        if (!jid.length || !mid.length) {
            if (callback)
                callback(null, {
                    "code": "invalid_request",
                    "message": "missing chat/id"
                });
            return;
        }
        const idx = root._messageIndex(mid);
        if (idx >= 0) {
            const cached = messagesModel.get(idx).media;
            if (cached && cached.downloaded && cached.path) {
                if (callback)
                    callback(cached, null);
                return;
            }
        }
        root._send("media.download", {
            "chat": jid,
            "id": mid
        }, function (res, err) {
            if (err || !res) {
                if (callback)
                    callback(null, err || {
                        "code": "download_failed",
                        "message": "media download failed"
                    });
                return;
            }
            const media = root._mediaObject({
                "media": res
            });
            const i = root._messageIndex(mid);
            if (i >= 0)
                messagesModel.setProperty(i, "media", media);
            if (callback)
                callback(media, null);
        });
    }

    function openMedia(chat, id, currentPath) {
        if (currentPath && String(currentPath).length) {
            root.openPath(currentPath);
            return;
        }
        root.downloadMedia(chat, id, function (media, err) {
            if (!err && media && media.path)
                root.openPath(media.path);
        });
    }

    // ------------------------------------------------------------------ //
    // Envio de mídia (1 arquivo por vez)
    // ------------------------------------------------------------------ //
    readonly property int mediaSizeLimit: 100 * 1024 * 1024

    function _basename(path) {
        const p = String(path || "");
        const i = p.lastIndexOf("/");
        return i >= 0 ? p.substring(i + 1) : p;
    }

    // Índice da bolha otimista pelo temp_id do upload.
    function _uploadIndex(tempId) {
        const t = String(tempId || "");
        if (!t.length)
            return -1;
        for (let i = 0; i < messagesModel.count; i++) {
            const up = messagesModel.get(i).upload;
            if (up && String(up.tempId || "") === t)
                return i;
        }
        return -1;
    }

    // Cria a bolha otimista e dispara media.send. Retorna false se inválido.
    function sendMedia(path, kind, mime, size, caption) {
        const jid = root.currentChat;
        const p = String(path || "");
        const k = String(kind || "");
        const n = Number(size || 0);
        const cap = String(caption || "");
        if (!jid.length || !p.length)
            return false;
        if (n > root.mediaSizeLimit) {
            root.lastError = "Arquivo maior que 100 MB";
            return false;
        }
        if (k !== "image" && k !== "video" && k !== "audio" && k !== "document") {
            root.lastError = "Tipo de arquivo não suportado";
            return false;
        }

        const replyId = root.replyToId;
        if (replyId.length)
            root.clearReply();

        const tempId = "tmp-" + (++root._tempSeq);
        const upload = {
            "state": "sending",
            "pct": 0,
            "tempId": tempId,
            "name": root._basename(p),
            "size": n,
            "kind": k,
            "mime": String(mime || ""),
            "caption": cap,
            "replyTo": replyId,
            "path": p,
            "error": ""
        };
        const media = {
            "kind": k,
            "mime": String(mime || ""),
            "size": n,
            "width": 0,
            "height": 0,
            "downloaded": false,
            "thumb": "",
            "path": "",
            "duration": 0
        };
        messagesModel.append(root._messageRow({
            "id": tempId,
            "chat": jid,
            "sender": root.accountJid,
            "fromMe": true,
            "timestamp": String(Date.now()),
            "type": k,
            "text": cap,
            "status": "sending",
            "media": media,
            "localPath": p,
            "upload": upload
        }));

        root._send("media.send", {
            "chat": jid,
            "path": p,
            "caption": cap.length ? cap : null,
            "reply_to": replyId.length ? replyId : null
        }, function (res, err) {
            if (err || !res) {
                root._markUploadFailed(tempId, err);
                return;
            }
            root._reconcileUpload(tempId, jid, res);
        });
        return true;
    }

    function _markUploadFailed(tempId, err) {
        const idx = root._uploadIndex(tempId);
        if (idx < 0)
            return;
        const row = messagesModel.get(idx);
        const up = Object.assign({}, row.upload);
        up.state = "failed";
        up.pct = 0;
        up.error = root._errorMessage(err) || "send_failed";
        messagesModel.setProperty(idx, "upload", up);
        messagesModel.setProperty(idx, "status", "failed");
        root.lastError = up.error;
    }

    function _reconcileUpload(tempId, jid, res) {
        const realId = String(res.id || "");
        const tmpIdx = root._uploadIndex(tempId);
        const realIdx = realId.length ? root._messageIndex(realId) : -1;
        const media = root._mediaObject({
            "media": res
        });
        const row = root._messageRow({
            "id": realId.length ? realId : tempId,
            "chat": jid,
            "sender": root.accountJid,
            "fromMe": true,
            "timestamp": String(Date.now()),
            "type": String(res.kind || "document"),
            "text": String(res.caption || ""),
            "status": "sent",
            "media": res
        });
        if (realIdx >= 0) {
            // O eco (message.received) chegou antes: descarta a bolha otimista e
            // completa a mensagem real com a mídia do cache. Recalcula o índice
            // real após a remoção (ele pode deslocar).
            if (tmpIdx >= 0)
                messagesModel.remove(tmpIdx);
            const ri = root._messageIndex(realId);
            if (ri >= 0) {
                messagesModel.setProperty(ri, "media", media);
                messagesModel.setProperty(ri, "status", "sent");
            }
        } else if (tmpIdx >= 0) {
            messagesModel.set(tmpIdx, row);
        } else {
            messagesModel.append(row);
        }
        root._bumpChatPreview(jid, root._previewFor({
            "type": String(res.kind || "document"),
            "text": String(res.caption || "")
        }), String(Date.now()), false);
        root.messageAppended(jid);
    }

    function retryUpload(tempId) {
        const idx = root._uploadIndex(tempId);
        if (idx < 0)
            return;
        const row = messagesModel.get(idx);
        const jid = String(row.chat || root.currentChat);
        const up = Object.assign({}, row.upload);
        up.state = "sending";
        up.pct = 0;
        up.error = "";
        messagesModel.setProperty(idx, "upload", up);
        messagesModel.setProperty(idx, "status", "sending");
        root._send("media.send", {
            "chat": jid,
            "path": up.path,
            "caption": String(up.caption || "").length ? up.caption : null,
            "reply_to": String(up.replyTo || "").length ? up.replyTo : null
        }, function (res, err) {
            if (err || !res) {
                root._markUploadFailed(tempId, err);
                return;
            }
            root._reconcileUpload(tempId, jid, res);
        });
    }

    function discardUpload(tempId) {
        const idx = root._uploadIndex(tempId);
        if (idx >= 0)
            messagesModel.remove(idx);
    }

    function _onMediaUpload(data) {
        const tempId = String(data.temp_id || "");
        const idx = root._uploadIndex(tempId);
        if (idx < 0)
            return;
        const row = messagesModel.get(idx);
        const up = Object.assign({}, row.upload);
        up.pct = Math.max(0, Math.min(100, Number(data.pct || 0)));
        up.state = "sending";
        messagesModel.setProperty(idx, "upload", up);
    }

    function send(text) {
        const body = String(text || "");
        const jid = root.currentChat;
        if (!body.length || !jid)
            return false;
        const replyId = root.replyToId;
        if (replyId.length) {
            const rName = root.replyToName;
            const rText = root.replyToText;
            const rFromMe = root.replyToFromMe;
            root.clearReply();
            root._send("message.reply", {
                "jid": jid,
                "id": replyId,
                "text": body
            }, function (res, err) {
                if (err || !res) {
                    root.lastError = root._errorMessage(err) || "send_failed";
                    return;
                }
                root._appendMessageIfNew({
                    "messageId": res.id,
                    "chat": jid,
                    "sender": root.accountJid,
                    "fromMe": true,
                    "timestamp": res.timestamp,
                    "type": "text",
                    "text": body,
                    "quotedId": replyId,
                    "quotedText": rText,
                    "quotedFromMe": rFromMe,
                    "status": "sent"
                });
                root._bumpChatPreview(jid, body, res.timestamp, false);
                root.messageAppended(jid);
            });
            return true;
        }
        root._send("message.send", {
            "jid": jid,
            "text": body
        }, function (res, err) {
            if (err || !res) {
                root.lastError = root._errorMessage(err) || "send_failed";
                return;
            }
            root._appendMessageIfNew({
                "messageId": res.id,
                "chat": jid,
                "sender": root.accountJid,
                "fromMe": true,
                "timestamp": res.timestamp,
                "type": "text",
                "text": body,
                "status": "sent"
            });
            root._bumpChatPreview(jid, body, res.timestamp, false);
            root.messageAppended(jid);
        });
        return true;
    }

    function markRead() {
        const jid = root.currentChat;
        if (!jid)
            return;
        root._send("message.read", {
            "jid": jid
        }, function (res, err) {
            if (err)
                return;
            const idx = root._chatIndex(jid);
            if (idx >= 0 && Number(chatsModel.get(idx).unread || 0) > 0) {
                chatsModel.setProperty(idx, "unread", 0);
                root._recountUnread();
            }
        });
    }

    // ------------------------------------------------------------------ //
    // Autenticação
    // ------------------------------------------------------------------ //
    function startLogin() {
        root.qrPng = "";
        root.lastError = "";
        root.authState = "connecting";
        loginWatch.stop();
        // Limpa qualquer pareamento anterior antes de pedir um novo: um QR que
        // expirou por timeout ou um login cujo dono IPC sumiu deixariam o
        // daemon respondendo login_in_progress. no_login_active é esperado e
        // ignorado; o erro de transporte também não impede a nova tentativa.
        root._send("auth.cancel", null, function () {
            root._send("auth.start", null, function (res, err) {
                if (err) {
                    loginWatch.stop();
                    root.lastError = root._errorMessage(err) || "falha ao iniciar o pareamento";
                    root.authState = "needs_pairing";
                    return;
                }
                // A resposta chegou; se nenhum auth.qr vier, o watchdog fecha
                // a UI em estado de falha com a ação de tentar novamente.
                loginWatch.restart();
            });
        });
    }

    function cancelLogin() {
        loginWatch.stop();
        root._send("auth.cancel", null, function (res, err) {
            if (err) {
                root.lastError = root._errorMessage(err);
                if (!root.loggedIn && root.authState !== "connected")
                    root.authState = "needs_pairing";
            }
        });
    }

    function logout() {
        loginWatch.stop();
        root._send("auth.logout", null, function (res, err) {
            if (err) {
                root.lastError = root._errorMessage(err);
                return;
            }
            root.loggedIn = false;
            root.authState = "needs_pairing";
            root.qrPng = "";
            root.currentChat = "";
            root.currentChatName = "";
            chatsModel.clear();
            messagesModel.clear();
            root.unreadCount = 0;
        });
    }

    function clearError() {
        root.lastError = "";
    }
}
