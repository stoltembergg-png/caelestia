// WhatsAppNotifier — notificações de mensagens recebidas via D-Bus.
//
// Nunca cria um servidor de notificações (o core é dono de
// org.freedesktop.Notifications); apenas chama `Notify` por `gdbus` e escuta
// `ActionInvoked` por um `gdbus monitor` persistente para abrir o drawer.
//
// Regras:
//   * só notifica mensagens de entrada (`fromMe == false`);
//   * suprime quando o drawer está visível, quando o usuário desligou as
//     notificações ou quando o core está em Não Perturbe (`Notifs.dnd`);
//   * cooldown curto por conversa para evitar enxurrada de notificações;
//   * nunca registra em log o conteúdo nem credenciais.

pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.extras.whatsapp

Singleton {
    id: root

    // Janela mínima entre notificações da mesma conversa.
    readonly property int cooldownMs: 4000
    // Quantos ids nossos mantemos para casar com ActionInvoked.
    readonly property int maxTrackedIds: 8

    property var _notifyIds: []
    property var _cooldowns: ({})

    // Chamado pelo WhatsAppClient no boot para garantir que este singleton (e o
    // monitor D-Bus) existam antes da primeira mensagem.
    function warmup(): void {
    }

    function notify(jid, name, preview) {
        if (!WhatsAppSettings.getBool("notifications", true))
            return;
        if (WhatsAppState.visible)
            return;
        if (typeof Notifs !== "undefined" && Notifs.dnd)
            return;

        const key = String(jid || "");
        const now = Date.now();
        const last = root._cooldowns[key] || 0;
        if (now - last < root.cooldownMs)
            return;
        root._cooldowns[key] = now;

        const summary = (name && name.length) ? name : "WhatsApp";
        let body = (preview && preview.length) ? preview : "Nova mensagem";
        if (body.length > 140)
            body = body.substring(0, 139) + "…";

        notifyProc.command = [
            "gdbus", "call", "--session",
            "--dest", "org.freedesktop.Notifications",
            "--object-path", "/org/freedesktop/Notifications",
            "--method", "org.freedesktop.Notifications.Notify",
            "WhatsApp", "0", "", summary, body,
            '["default","Abrir"]', "{}", "5000"
        ];
        notifyProc.running = false;
        notifyProc.running = true;
    }

    function _trackId(id) {
        let ids = root._notifyIds.slice();
        ids.push(id);
        if (ids.length > root.maxTrackedIds)
            ids = ids.slice(ids.length - root.maxTrackedIds);
        root._notifyIds = ids;
    }

    Process {
        id: notifyProc

        command: []
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.match(/uint32\s+(\d+)/);
                if (m)
                    root._trackId(parseInt(m[1], 10));
            }
        }
    }

    // Monitor persistente: qualquer "default" de um id nosso abre o drawer.
    Process {
        id: actionMonitor

        command: ["gdbus", "monitor", "--session", "--dest", "org.freedesktop.Notifications"]
        running: true
        // qmllint disable signal-handler-parameters
        // O enum QProcess::ExitStatus não está no qmltypes; o handler é válido.
        onExited: actionMonitor.running = true
        // qmllint enable signal-handler-parameters
        stdout: SplitParser {
            onRead: line => {
                const at = line.indexOf("ActionInvoked");
                if (at < 0)
                    return;
                const tail = line.substring(at);
                if (tail.indexOf("'default'") < 0)
                    return;
                const m = tail.match(/uint32\s+(\d+)/);
                if (!m)
                    return;
                const id = parseInt(m[1], 10);
                if (root._notifyIds.indexOf(id) >= 0)
                    WhatsAppState.toggle();
            }
        }
    }
}
