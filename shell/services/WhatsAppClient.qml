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

    // Lista de conversas (chats.list / chat.updated).
    readonly property alias chats: chatsModel
    // Mensagens da conversa aberta, em ordem cronológica (antiga -> recente).
    readonly property alias messages: messagesModel

    // Sinais de conveniência para a UI.
    signal messageAppended(string jid)
    signal chatsRefreshed()

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

    Loader {
        id: sockLoader

        active: true
        asynchronous: false
        sourceComponent: Socket {
            path: root.socketPath
            connected: true

            parser: SplitParser {
                onRead: data => root._onLine(data)
            }

            onConnectedChanged: root._onSocketConnectedChanged(connected)
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

    // ------------------------------------------------------------------ //
    // Máquina de estado / correlação
    // ------------------------------------------------------------------ //
    property int _nextId: 0
    readonly property var _pending: ({})
    readonly property var _queue: []
    property int _pendingCount: 0
    property int _reconnectAttempts: 0
    property double _lastRxAt: 0
    readonly property int _requestTimeout: 15000
    readonly property int _maxQueue: 128
    property bool _shuttingDown: false

    function _syncPendingCount(): void {
        root._pendingCount = Object.keys(root._pending).length;
    }

    function _connected(): bool {
        return root.socket !== null && root.socket !== undefined && root.socketConnected;
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
        root.socket.write(JSON.stringify(payload) + "\n");
        root.socket.flush();
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
    function _onSocketConnectedChanged(connected) {
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
        root.connectionState = "connected";
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
            if (res.connection && res.connection.state)
                root.connectionState = String(res.connection.state);
            if (res.auth) {
                root.authState = String(res.auth.state || root.authState);
                root.loggedIn = res.auth.logged_in === true;
                root.pushName = String(res.auth.push_name || "");
                root.accountJid = String(res.auth.jid || "");
            }
            if (root.loggedIn)
                root.refreshChats();
        });
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
            root.loggedIn = true;
            root.authState = "connected";
            root.qrPng = "";
            root.pushName = String(data.push_name || root.pushName);
            root.accountJid = String(data.jid || root.accountJid);
            root.lastError = "";
            loginWatch.stop();
            root.refreshChats();
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
            root.connectionState = String(data.state || "disconnected");
            if (data.state === "connected" && root.authState === "connecting")
                root._bootstrap();
        } else if (name === "message.received") {
            root._onMessageReceived(data);
        } else if (name === "message.updated" || name === "message.deleted") {
            root._onMessageUpdated(data);
        } else if (name === "receipt.updated") {
            root._onReceiptUpdated(data);
        } else if (name === "chat.updated") {
            root._upsertChat(data.chat || data, true);
        }
    }

    // ------------------------------------------------------------------ //
    // Conversas
    // ------------------------------------------------------------------ //
    function _chatRow(c) {
        return {
            "jid": String(c.jid || ""),
            "kind": String(c.kind || "dm"),
            "name": String(c.name || c.jid || ""),
            "lastMessage": String(c.lastMessage || c.last_message || ""),
            "timestamp": String(c.timestamp || ""),
            "unread": Number(c.unread || c.unread_count || 0)
        };
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
        return idx >= 0 ? String(chatsModel.get(idx).name || jid) : String(jid || "");
    }

    function _recountUnread() {
        let total = 0;
        for (let i = 0; i < chatsModel.count; i++)
            total += Number(chatsModel.get(i).unread || 0);
        root.unreadCount = total;
    }

    function _upsertChat(c, moveTop) {
        if (!c || !c.jid)
            return;
        const row = root._chatRow(c);
        if (!row.jid)
            return;
        const idx = root._chatIndex(row.jid);
        if (idx < 0) {
            chatsModel.append(row);
        } else {
            // Preserva o contador de não lidas quando o evento não o traz.
            if (c.unread === undefined && c.unread_count === undefined)
                row.unread = Number(chatsModel.get(idx).unread || 0);
            chatsModel.set(idx, row);
        }
        const cur = root._chatIndex(row.jid);
        if (moveTop && cur > 0)
            chatsModel.move(cur, 0, 1);
        root._recountUnread();
        if (row.jid === root.currentChat)
            root.currentChatName = row.name;
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
            "unread": incrementUnread ? Number(c.unread || 0) + 1 : Number(c.unread || 0)
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
            for (let i = 0; i < list.length; i++)
                chatsModel.append(root._chatRow(list[i]));
            root._recountUnread();
            root.chatsRefreshed();
            if (root.currentChat)
                root.currentChatName = root._chatName(root.currentChat);
        });
    }

    function openChat(jid) {
        if (!jid)
            return;
        const id = String(jid);
        root.currentChat = id;
        root.currentChatName = root._chatName(id);
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
        messagesModel.clear();
    }

    // ------------------------------------------------------------------ //
    // Mensagens
    // ------------------------------------------------------------------ //
    function _messageRow(m) {
        return {
            "messageId": String(m.id || ""),
            "chat": String(m.chat || ""),
            "sender": String(m.sender || ""),
            "fromMe": m.fromMe === true,
            "timestamp": String(m.timestamp || ""),
            "type": String(m.type || "text"),
            "text": String(m.text || ""),
            "quotedId": String(m.quotedId || ""),
            "edited": m.edited === true,
            "deleted": m.deleted === true,
            "status": String(m.status || "")
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

        if (jid === root.currentChat) {
            if (!fromMe)
                root.markRead();
            root.messageAppended(jid);
        }
    }

    function _onMessageUpdated(data) {
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

    function _onReceiptUpdated(data) {
        const id = String(data.id || data.message_id || (data.message && data.message.id) || "");
        const status = String(data.status || (data.message && data.message.status) || "");
        if (!id || !status)
            return;
        const idx = root._messageIndex(id);
        if (idx >= 0)
            messagesModel.setProperty(idx, "status", status);
    }

    function send(text) {
        const body = String(text || "");
        const jid = root.currentChat;
        if (!body.length || !jid)
            return false;
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
