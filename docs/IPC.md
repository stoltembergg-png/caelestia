# IPC — protocolo do `caelestia-whatsappd`

Este documento descreve o contrato entre o daemon Go e o frontend QML
(`extras/services/WhatsApp.qml`) / a CLI `cwctl`. Ele é a referência pública do
socket Unix e **não deve ser quebrado sem versionamento**.

Referências: `docs/ARQUITETURA.md` §2.1, §3.3 e §8; `docs/BUILD.md`.

---

## 1. Visão geral

- Transporte: **Unix domain socket** em
  `${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock` (flag `--socket`).
- Sem TCP/HTTP. Sem abstract sockets.
- Codificação: **NDJSON** (uma mensagem JSON por linha, terminada em `\n`,
  UTF-8). Não há cabeçalhos, framing binário, `Content-Length` nem handshake.
- Modelo de mensagens:
  - **request** (cliente → daemon): tem `id` e `method`.
  - **response** (daemon → cliente): ecoa o `id` e traz `result` **ou** `error`.
  - **event** (daemon → todos os clientes): tem `event` e `data`, **sem** `id`.
    Eventos são *push* e não devem ser correlacionados com requests pendentes.

O daemon aceita múltiplas conexões simultâneas; cada conexão tem sua própria
thread de leitura. As respostas de uma conexão e os eventos (*broadcast*) são
serializados por mutex, portanto **nunca** se intercalam bytes na linha.

---

## 2. Envelope

### 2.1 Request

```json
{"id":1,"method":"ping","params":{"echo":"oi"}}
```

| Campo    | Tipo              | Obrigatório | Regra |
|---|---|---|---|
| `id`     | inteiro (uint64)  | **sim**     | identificador escolhido pelo cliente; ecoado na resposta |
| `method` | string            | **sim**     | `ns.verb`, no máximo **64 caracteres**, não vazio |
| `params` | objeto ou `null`  | não         | payload específico do método; omitido equivale a `null` |

O servidor rejeita (sem `panic`) requests que não sejam um objeto JSON, que
tenham `id`/`method` ausentes ou de tipo errado, `method` longo demais, ou
`params` que não seja objeto/`null`. Os erros são explicados na seção 4.

### 2.2 Response

Sucesso:

```json
{"id":1,"result":{"pong":true,"version":"0.1.0-dev"}}
```

Erro:

```json
{"id":1,"error":{"code":"method_not_found","message":"unknown method: foo.bar"}}
```

Exatamente um entre `result` e `error` está presente. Em caso de sucesso com
resultado nulo, `"result":null` é enviado de forma explícita.

### 2.3 Event

```json
{"event":"auth.qr","data":{"code":"2@abc...","timeout":60,"png_base64":"iVBORw0KGgo..."}}
```

| Campo   | Tipo   | Descrição |
|---|---|---|
| `event` | string | `ns.verb` do evento |
| `data`  | objeto | payload do evento |

Eventos são enviados a **todos** os clientes conectados (`Server.Broadcast`) e
não geram resposta.

No evento `auth.qr`, `png_base64` é uma imagem PNG 256×256 do `code` codificada
em base64 **padrão**, pronta para o frontend QML renderizar sem precisar de uma
biblioteca de QR no lado do shell. Tanto `code` quanto `png_base64` são
segredos: circulam apenas no IPC e **nunca** aparecem no log.

### 2.4 Inteiros de 64 bits: use string

O frontend é QML/JavaScript, cujo tipo `Number` é um `double` IEEE-754 e só
representa inteiros com exatidão até `2^53 - 1`. IDs de mensagem do WhatsApp e
timestamps em milissegundos podem ultrapassar esse limite.

**Regra:** dentro de **eventos** (e de resultados de request), qualquer inteiro
de 64 bits (`message.id`, `timestamp`, `server_id`, …) deve ser serializado como
**string decimal**, nunca como número JSON.

```json
{"event":"message.received","data":{"chat":"...","message":{"id":"3EB0...","timestamp":"1730000000000"}}}
```

No Go, use os helpers de `internal/ipc` em vez de formatar à mão:

```go
ipc.StringID(msgID)            // uint64 -> "12345678901234567890"
ipc.StringTimestamp(tsMillis)  // int64  -> "1730000000000"
```

O campo `id` do envelope (correlação de request/response) continua sendo um
número: é gerado pelo cliente e fica bem abaixo de `2^53`.

---

## 3. Framing NDJSON

- Cada linha é um objeto JSON completo, separado por `\n` (LF).
- Linhas vazias (ou só espaços) são ignoradas.
- Não é permitido quebrar uma mensagem em várias linhas.
- Linha máxima: **1 MiB** por padrão (`ipc.DefaultMaxLineBytes`), configurável no
  servidor via `ipc.WithMaxLineBytes(n)`.
- Mídia **nunca** trafega inline: apenas caminho/metadados (ver §3.5 do
  ARQUITETURA). Isso mantém as linhas pequenas.
- Se uma linha excede o limite, o servidor responde `parse_error`, registra o
  evento e **encerra a conexão** (o framing não pode ser ressincronizado).

---

## 4. Códigos de erro

Estáveis e parte do contrato — clientes podem (e devem) ramificar por `code`.

| `code`               | Significado | Exemplos de causa |
|---|---|---|
| `parse_error`        | A linha não é JSON válido, ou um campo tem tipo JSON incompatível. | `{"id":1,"method":` ; `id` como string ; linha gigante |
| `invalid_request`    | JSON válido, envelope inválido. | falta `id`; falta/`method` vazio; `method` > 64 chars; `params` não é objeto/`null` |
| `method_not_found`   | Método não registrado no daemon. | `foo.bar`; método de fase futura |
| `internal_error`     | Falha interna/`panic` no handler. | bug de handler; resultado não serializável |
| `not_paired`         | Não há sessão pareada para executar a operação. | `message.send`/`chat.messages` antes do login; `chats.list` sem device |
| `not_found`          | O recurso pedido não existe localmente. | `chat.open` de um JID desconhecido |
| `send_failed`        | A operação de rede com o WhatsApp falhou. | `message.send` com a conexão caída; `message.read` recusado |
| `no_login_active`    | `auth.cancel` chamado sem login em andamento. | cancelar após o pareamento concluir/expirar |

`parse_error`, `invalid_request` e `method_not_found` são emitidos pela camada
de protocolo; `not_paired`, `not_found`, `send_failed` e `no_login_active` são
específicos dos métodos de domínio e também são estáveis.

O daemon **nunca** derruba o processo por payload inválido. Existe ainda um
orçamento de erros consecutivos por conexão (padrão: 16, ajustável por
`ipc.WithMaxConsecutiveErrors`); ao estourar, a conexão é fechada.

**Orçamento de erros.** Contam para o orçamento apenas falhas de
protocolo/transporte: JSON inválido, envelope inválido, `method` inexistente,
falha ao serializar a resposta ou `panic` no handler. Um **erro de domínio** bem
formado (`not_paired`, `not_found`, `send_failed`, `no_login_active`, …) é uma
resposta válida: é devolvido ao cliente normalmente e **reseta** o orçamento,
como um sucesso. Assim, repetir uma operação inválida não derruba a conexão.

---

## 5. Limites e segurança

Baseado em `ARQUITETURA.md` §8:

- Socket em `$XDG_RUNTIME_DIR` (diretório `0700`) com `chmod 0600`; o daemon
  remove um socket órfão antes de abrir e remove o arquivo no shutdown.
- O daemon recusa conexões cujo **peer UID** difira do UID do processo, obtido
  via `SO_PEERCRED` (`golang.org/x/sys/unix`). Falha ao ler as credenciais =>
  conexão recusada.
- Validação estrita do envelope e dos campos; sem `panic`.
- Sem segredos em log; a sessão do WhatsApp permanece no SQLite `0600` e nunca é
  exposta no IPC.
- `id` obrigatório, `method` limitado a 64 caracteres, linha limitada a 1 MiB.
- Escrita serializada por conexão (mutex); broadcast itera uma cópia da lista.
- Escrita com **deadline** (padrão 5 s, `ipc.WithWriteTimeout`): um cliente que
  para de ler é fechado em vez de travar o escritor, e uma linha parcial nunca é
  seguida de outro frame.
- Limite opcional de conexões (`ipc.WithMaxConns`) e deadline ocioso de leitura
  opcional (`ipc.WithReadIdleTimeout`, desligado por padrão — um cliente que só
  aguarda eventos, como `cwctl login`, não é derrubado).
- Instância única por `--data-dir`: o daemon toma um `flock(LOCK_EX|LOCK_NB)` em
  `<data-dir>/daemon.lock` antes de abrir o banco/socket e recusa uma segunda
  instância (ver `TROUBLESHOOTING.md`).

---

## 6. Métodos implementados

### `ping`

Verifica que o daemon está vivo e respondendo.

Request:

```json
{"id":1,"method":"ping"}
```

Response:

```json
{"id":1,"result":{"pong":true,"version":"0.1.0-dev"}}
```

### `status`

Snapshot geral do daemon, incluindo o estado de conexão/autenticação (fase 2.3).

Request:

```json
{"id":2,"method":"status"}
```

Response:

```json
{
  "id": 2,
  "result": {
    "version": "0.1.0-dev",
    "uptime_seconds": 42,
    "data_dir": "/home/user/.local/share/caelestia-whatsapp",
    "socket": "/run/user/1000/caelestia-whatsapp.sock",
    "connection": {"state": "needs_pairing"},
    "auth": {"state": "needs_pairing", "logged_in": false}
  }
}
```

### `auth.start` (fase 2.3)

Inicia o fluxo de pareamento por QR code. O daemon chama `GetQRChannel` **antes**
do `Connect` e passa a emitir eventos `auth.qr` (com `code`, `timeout` e o
`png_base64` do QR). Nem o código nem o PNG **nunca** são registrados em log
(apenas `"qr emitted"`).

Request:

```json
{"id":3,"method":"auth.start"}
```

Response (aceito):

```json
{"id":3,"result":{"started":true}}
```

Erros: se já existe sessão ou um login já está em andamento, responde
`invalid_request` (ex.: `whatsapp: already logged in`). Toda recusa é registrada
no journal em INFO com `reason=...` (ex.: `login already active`,
`device already paired`), sem segredos.

O login em andamento é abortável por `auth.cancel` (abaixo), `auth.logout` ou
pelo shutdown do daemon; whatsmeow não fecha o canal de QR em todos os
desfechos (ex.: `err-scanned-without-multidevice`), então o daemon mantém um
contexto cancelável por login e encerra a tentativa assim que ela vira terminal.
Assim, **timeout, cancel e erro liberam `auth.start` para uma nova tentativa**,
que emite um novo `auth.qr`; uma tentativa ainda ativa continua respondendo
`login_in_progress`.

### `auth.cancel` (fase 2.5)

Cancela um pareamento por QR em andamento. O canal de QR é abandonado e nenhum
`auth.qr` posterior é emitido. Útil para abortar um `cwctl login` sem reiniciar
o daemon.

Request:

```json
{"id":4,"method":"auth.cancel"}
```

Response:

```json
{"id":4,"result":{"canceled":true}}
```

Erro: `no_login_active` quando não há login em andamento.

### `auth.status` (fase 2.3)

Estado atual da autenticação. `jid`/`push_name` só aparecem quando conhecidos;
`banned_until` (RFC 3339) só aparece durante um banimento temporário.

Request:

```json
{"id":4,"method":"auth.status"}
```

Response (sem sessão):

```json
{"id":4,"result":{"state":"needs_pairing","logged_in":false}}
```

Response (conectado):

```json
{
  "id": 5,
  "result": {
    "state": "connected",
    "logged_in": true,
    "jid": "5511999999999@s.whatsapp.net",
    "push_name": "Fulano"
  }
}
```

Estados possíveis: `disconnected`, `connecting`, `connected`, `needs_pairing`,
`logged_out`, `banned`, `outdated`, `stream_replaced`.

### `auth.logout` (fase 2.3)

Desvincula o dispositivo, apaga a sessão local e volta a `needs_pairing`.

Request:

```json
{"id":6,"method":"auth.logout"}
```

Response:

```json
{"id":6,"result":{"logged_out":true,"state":"needs_pairing"}}
```

### `chats.list` (fase 2.4)

Lista as conversas locais, ordenadas por `timestamp` decrescente (sem
mensagem vai por último). Lê o banco local; ainda assim exige uma sessão
pareada (`not_paired` sem device).

Request:

```json
{"id":10,"method":"chats.list","params":{"limit":50}}
```

`limit` é opcional (padrão 100, máximo 1000).

Response:

```json
{
  "id": 10,
  "result": [
    {
      "jid": "5511999999999@s.whatsapp.net",
      "kind": "dm",
      "name": "Fulano",
      "lastMessage": "cheguei!",
      "timestamp": "1730000000000",
      "unread": 2
    }
  ]
}
```

Campos: `jid`, `kind` (`dm`/`group`), `name` (contato > push > JID),
`lastMessage` (preview), `timestamp` (**string** de milissegundos; `""` quando
desconhecido), `unread`. `lastMessageId` aparece quando conhecido.

### `chat.open` (fase 2.4)

Metadados de uma conversa. Erros: `invalid_request` (sem `jid`),
`not_found` (JID desconhecido), `not_paired`.

Request:

```json
{"id":11,"method":"chat.open","params":{"jid":"5511999999999@s.whatsapp.net"}}
```

Response: um único objeto com os mesmos campos de `chats.list`.

### `chat.messages` (fase 2.4)

Histórico de uma conversa, **mais recentes primeiro**. `limit` é opcional
(padrão 100); `before` é um timestamp em milissegundos (número **ou** string) e
retorna apenas mensagens estritamente mais antigas.

Request:

```json
{"id":12,"method":"chat.messages","params":{"jid":"5511999999999@s.whatsapp.net","limit":50,"before":"1730000000000"}}
```

Response:

```json
{
  "id": 12,
  "result": [
    {
      "id": "3EB0...",
      "chat": "5511999999999@s.whatsapp.net",
      "sender": "5511999999999@s.whatsapp.net",
      "fromMe": false,
      "timestamp": "1730000001000",
      "type": "text",
      "text": "oi",
      "quotedId": "",
      "edited": false,
      "deleted": false,
      "status": ""
    }
  ]
}
```

`type` é uma classificação grosseira (`text`, `image`, `video`, `audio`,
`document`, `sticker`, `location`, `contact`, `reaction`, `protocol`,
`unknown`). `status` é `sent`/`delivered`/`read` para mensagens enviadas.

> **Semântica de persistência (persist).**
>
> - **Reações não são mensagens.** Uma reação é gravada apenas como metadado
>   (tabela `cae_reactions`, chave `(message_id, sender_jid)`); ela **nunca**
>   cria linha em `cae_messages`, não entra em `chat.messages` e **não** altera
>   `last_message`/`last_preview` nem o contador `unread`. Emoji vazio remove a
>   reação.
> - **Mensagens de protocolo** que não sejam `REVOKE` ou `MESSAGE_EDIT` são
>   ignoradas por completo: não geram linha `type=protocol` nem incrementam
>   `unread`. `REVOKE` marca a mensagem como apagada e `MESSAGE_EDIT` atualiza o
>   texto.
> - **Unidades de timestamp.** No banco, `cae_messages.timestamp` e
>   `cae_receipts.ts` são Unix em **milissegundos** (coerentes com os valores
>   expostos aqui como string). As demais colunas temporais — `created_at`,
>   `updated_at`, `last_connect_at`, `downloaded_at` — usam segundos
>   (`unixepoch()`).
> - **Contatos.** O nome de um contato só é atualizado a partir de mensagens
>   recebidas; mensagens próprias (`fromMe`) não gravam o nosso push name no
>   JID do par.
> - **History sync** aplica cada conversa em uma transação (`Repo.WithTx`)
>   mantendo a idempotência dos inserts. O history sync **não** publica eventos
>   de domínio (é backfill, não mensagem em tempo real): os eventos ao vivo
>   saem apenas do dispatcher de `Message`/`Receipt`. Priorização/paralelismo do
>   history sync em uma lane separada fica para antes da F4.

### `message.send` (fase 2.4)

Envia texto. Erros: `not_paired`, `invalid_request` (JID/texto inválidos),
`send_failed`.

Request:

```json
{"id":13,"method":"message.send","params":{"jid":"5511999999999@s.whatsapp.net","text":"olá"}}
```

Response:

```json
{"id":13,"result":{"id":"3EB0...","timestamp":"1730000001000"}}
```

A mensagem enviada é persistida localmente (aparece em `chat.messages`).

### `message.reply` (fase 2.4)

Igual a `message.send`, mas citando a mensagem `id` (via `ContextInfo`). O
`Participant` do contexto é o remetente da mensagem citada, quando conhecido.

Request:

```json
{"id":14,"method":"message.reply","params":{"jid":"5511999999999@s.whatsapp.net","id":"3EB0...","text":"concordo"}}
```

### `message.read` (fase 2.4)

Marca como lidas as mensagens recebidas pendentes do chat (`MarkRead` das
pendentes, agrupadas por remetente) e zera o contador de não lidas. Erros:
`not_paired`, `invalid_request`, `send_failed`.

Request:

```json
{"id":15,"method":"message.read","params":{"jid":"5511999999999@s.whatsapp.net"}}
```

Response:

```json
{"id":15,"result":{"read":2}}
```

### `contacts.search` (fase 2.4)

Busca contatos locais por `LIKE` sobre JID/nome. `limit` opcional. Os curingas
`%` e `_` digitados na query são tratados **literalmente** (escape `\`), então
uma busca por `%` não retorna todos os contatos.

Request:

```json
{"id":16,"method":"contacts.search","params":{"query":"fulano","limit":20}}
```

Response:

```json
{
  "id": 16,
  "result": [
    {"jid":"5511999999999@s.whatsapp.net","name":"Fulano","firstName":"","fullName":"Fulano de Tal","pushName":"Fulano"}
  ]
}
```

---

## 7. Métodos e eventos — status

Ainda **não** implementados; um request a eles responde `method_not_found`. A
tabela congela os nomes para o contrato não mudar quando forem implementados.

Já implementados: `auth.start|status|cancel|logout` e, na fase 2.4,
`chats.list`, `chat.open`, `chat.messages`, `message.send`, `message.reply`,
`message.read` e `contacts.search` (ver §6).

Métodos restantes (de `ARQUITETURA.md` §3.3):

| Método | Descrição |
|---|---|
| `message.react` | reação |
| `media.download` | baixa mídia para o cache e devolve caminho/metadados |
| `media.send` | envia mídia a partir de um caminho local |
| `presence.typing` | envia/atualiza indicador de digitação |
| `presence.available` | presença do usuário |

Eventos (push, sem `id`):

### 7.1 Autenticação e conexão (fase 2.3)

| Evento | Descrição |
|---|---|
| `auth.qr` | novo código QR (`{code, png_base64, timeout}`); `code` e `png_base64` vão só no IPC, nunca no log |
| `auth.connected` | pareamento/autenticação concluídos (`{jid?, push_name?}`) |
| `auth.disconnected` | sessão desconectada/logout (`{reason}`) |
| `auth.error` | erro de pareamento (`{message}`): timeout, QR inválido, client outdated… |
| `connection.updated` | estado da conexão (`{state, since}`), emitido a cada transição |

### 7.2 Domínio (fase 3) — **implementados**

Emitidos pelo `Persister` **depois** de a alteração ser gravada no SQLite
(persistir-antes-de-publicar) e sem bloquear o handler do whatsmeow: o handler
apenas classifica e enfileira, e um único worker persiste e publica. O hook é
ligado em `main.go` a `ipcServer.Broadcast`; no shutdown o `Persister` é
fechado e drenado **antes** do servidor IPC, então os eventos que já estavam na
fila ainda são emitidos para os clientes conectados.

| Evento | `data` | Quando |
|---|---|---|
| `message.received` | `{chat, sender, id, text, timestamp, from_me, type}` | mensagem **nova** inserida (entrada ou eco próprio de outro dispositivo) |
| `message.updated` | `{chat, id, edited?, deleted?}` | `REVOKE` (`deleted:true`) ou `MESSAGE_EDIT` (`edited:true`); o campo que não se aplica é omitido |
| `receipt.updated` | `{chat, ids, status}` | recibo (`delivered` ou `read`); `ids` é uma lista de strings |
| `chat.updated` | `{jid, name?, unread, last_message, last_ts}` | `unread` ou a última mensagem mudou (mensagem nova ou leitura que zera o contador); `name` só quando conhecido |

Exemplos:

```json
{"event":"message.received","data":{"chat":"5511999999999@s.whatsapp.net","sender":"5511999999999@s.whatsapp.net","id":"3EB0...","text":"oi","timestamp":"1730000001000","from_me":false,"type":"text"}}
{"event":"message.updated","data":{"chat":"5511999999999@s.whatsapp.net","id":"3EB0...","deleted":true}}
{"event":"message.updated","data":{"chat":"5511999999999@s.whatsapp.net","id":"3EB0...","edited":true}}
{"event":"receipt.updated","data":{"chat":"5511999999999@s.whatsapp.net","ids":["3EB0..."],"status":"read"}}
{"event":"chat.updated","data":{"jid":"5511999999999@s.whatsapp.net","name":"Fulano","unread":2,"last_message":"oi","last_ts":"1730000001000"}}
```

`last_message` é o preview exibido na lista de conversas (não o `id`);
`timestamp` e `last_ts` são strings de milissegundos. Reações e mensagens de
protocolo que não sejam `REVOKE`/`MESSAGE_EDIT` **não** geram nenhum evento. O
**history sync** também não emite: é backfill e não mensagem em tempo real.

> Apagar uma mensagem é sinalizado por `message.updated {deleted:true}`; não há
> um evento `message.deleted` separado (nome unificado no contrato).

### 7.3 Planejados (fase 2.5+)

| Evento | Descrição |
|---|---|
| `typing.updated` | presença de digitação |

> Lembrete: IDs e timestamps de 64 bits nesses eventos vão como **string**
> (seção 2.4).

---

## 8. Exemplos completos

Request e response (ARQUITETURA §3.3):

```
→ {"id":1,"method":"status","params":{}}
← {"id":1,"result":{"version":"0.1.0-dev","uptime_seconds":42,"connection":{"state":"needs_pairing"},"auth":{"state":"needs_pairing","logged_in":false}}}
```

Fluxo de login por QR:

```
→ {"id":2,"method":"auth.status"}
← {"id":2,"result":{"state":"needs_pairing","logged_in":false}}

→ {"id":3,"method":"auth.start"}
← {"id":3,"result":{"started":true}}

← {"event":"auth.qr","data":{"code":"2@abcd...","timeout":60,"png_base64":"iVBORw0KGgo..."}}

← {"event":"auth.connected","data":{"jid":"5511999999999@s.whatsapp.net","push_name":"Fulano"}}
← {"event":"connection.updated","data":{"state":"connected","since":"1730000000000"}}
```

Erro:

```
→ {"id":9,"method":"foo.bar","params":{}}
← {"id":9,"error":{"code":"method_not_found","message":"unknown method: foo.bar"}}
```

Erro de domínio (sem sessão):

```
→ {"id":10,"method":"chats.list","params":{"limit":50}}
← {"id":10,"error":{"code":"not_paired","message":"whatsapp: no paired device"}}
```

Exemplo equivalente com a CLI `cwctl` (ver `docs/BUILD.md`):

```sh
cwctl --socket /tmp/cw.sock status
cwctl --socket /tmp/cw.sock chats --limit 20
cwctl --socket /tmp/cw.sock messages '5511999999999@s.whatsapp.net' --limit 50
cwctl --socket /tmp/cw.sock send '5511999999999@s.whatsapp.net' 'olá!'
```

Exemplo de cliente Python (UDS, usado no smoke manual):

```python
import json, socket

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect("/tmp/cw-test.sock")
s.sendall(b'{"id":1,"method":"ping"}\n')
print(s.recv(4096).decode())          # {"id":1,"result":{"pong":true,...}}
s.sendall(b'{"id":2,"method":"auth.status"}\n')
print(s.recv(4096).decode())          # {"id":2,"result":{"state":"needs_pairing",...}}
s.sendall(b'{"id":3,"method":"nao.existe"}\n')
print(s.recv(4096).decode())          # {"id":3,"error":{"code":"method_not_found",...}}
```

---

## 9. Rodando o daemon

```sh
cd ~/caelestia-whatsapp/daemon
go build -o bin/caelestia-whatsappd ./cmd/caelestia-whatsappd

./bin/caelestia-whatsappd \
  --data-dir /tmp/cw-data \
  --socket   /tmp/cw.sock \
  --log-level debug
```

Ao receber `SIGINT`/`SIGTERM`, o daemon para de aceitar conexões, fecha os
clientes, remove o socket, fecha o banco e sai com código `0`.
