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
{"event":"auth.qr","data":{"code":"2@abc...","timeout":60}}
```

| Campo   | Tipo   | Descrição |
|---|---|---|
| `event` | string | `ns.verb` do evento |
| `data`  | objeto | payload do evento |

Eventos são enviados a **todos** os clientes conectados (`Server.Broadcast`) e
não geram resposta.

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
| `method_not_found`   | Método não registrado no daemon. | `foo.bar`; métodos ainda não implementados (fase 2.3+) |
| `internal_error`     | Falha interna/`panic` no handler. | bug de handler; resultado não serializável |

O daemon **nunca** derruba o processo por payload inválido. Existe ainda um
orçamento de erros consecutivos por conexão (padrão: 16, ajustável por
`ipc.WithMaxConsecutiveErrors`); ao estourar, a conexão é fechada.

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
do `Connect` e passa a emitir eventos `auth.qr`. O código do QR **nunca** é
registrado em log (apenas `"qr emitted"`).

Request:

```json
{"id":3,"method":"auth.start"}
```

Response (aceito):

```json
{"id":3,"result":{"started":true}}
```

Erros: se já existe sessão ou um login já está em andamento, responde
`invalid_request` (ex.: `whatsapp: already logged in`).

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

---

## 7. Métodos e eventos planejados (fase 2.4+)

Ainda **não** implementados; um request a eles responde `method_not_found`. A
tabela congela os nomes para o contrato não mudar quando forem implementados.
(`auth.start`, `auth.status` e `auth.logout` já estão implementados — ver §6.)

Métodos (de `ARQUITETURA.md` §3.3):

| Método | Descrição |
|---|---|
| `chats.list` | lista de conversas |
| `chat.open` | abre uma conversa |
| `chat.messages` | histórico recente/paginado de uma conversa |
| `message.send` | envia texto |
| `message.reply` | responde citando uma mensagem |
| `message.react` | reação |
| `message.read` | marca como lido |
| `contacts.search` | busca de contatos |
| `media.download` | baixa mídia para o cache e devolve caminho/metadados |
| `media.send` | envia mídia a partir de um caminho local |
| `presence.typing` | envia/atualiza indicador de digitação |
| `presence.available` | presença do usuário |

Eventos (push, sem `id`):

Implementados na fase 2.3:

| Evento | Descrição |
|---|---|
| `auth.qr` | novo código QR (`{code, timeout}`); o `code` vai só no IPC, nunca no log |
| `auth.connected` | pareamento/autenticação concluídos (`{jid?, push_name?}`) |
| `auth.disconnected` | sessão desconectada/logout (`{reason}`) |
| `auth.error` | erro de pareamento (`{message}`): timeout, QR inválido, client outdated… |
| `connection.updated` | estado da conexão (`{state, since}`), emitido a cada transição |

Planejados (fase 2.4+):

| Evento | Descrição |
|---|---|
| `message.received` | nova mensagem |
| `message.updated` | mensagem editada/atualizada |
| `message.deleted` | mensagem apagada |
| `receipt.updated` | recibo (entregue/lido) |
| `chat.updated` | metadados da conversa mudaram |
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

← {"event":"auth.qr","data":{"code":"2@abcd...","timeout":60}}

← {"event":"auth.connected","data":{"jid":"5511999999999@s.whatsapp.net","push_name":"Fulano"}}
← {"event":"connection.updated","data":{"state":"connected","since":"1730000000000"}}
```

Erro:

```
→ {"id":9,"method":"message.send","params":{"chat":"..."}}
← {"id":9,"error":{"code":"method_not_found","message":"unknown method: message.send"}}
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
