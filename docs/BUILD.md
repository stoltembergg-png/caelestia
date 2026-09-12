# BUILD — compilar, testar e rodar o daemon e a CLI

Este documento cobre o backend Go (`daemon/`), a CLI `cwctl` (`cli/cwctl/`,
um **módulo Go separado**) e a instalação como serviço de usuário (systemd). O
shell (QML) é um passo posterior.

## Toolchain

O projeto usa **Go 1.26+**. O toolchain local fica em `~/.local/opt/go` e está
exposto em `~/.local/bin/go` (já no `PATH`):

```sh
go version   # go1.27.1 linux/amd64 (ou >= 1.26)
```

Nenhum passo exige `sudo`. Os pacotes ficam no `GOPATH` do usuário
(`~/go/pkg/mod`) e o build não usa CGO (driver `modernc.org/sqlite` é Go puro).

## Build

Tudo é executado a partir de `daemon/`:

```sh
cd ~/caelestia-whatsapp/daemon

# compila todos os pacotes
go build ./...

# binário do daemon
mkdir -p bin
go build -o bin/caelestia-whatsappd ./cmd/caelestia-whatsappd
```

## Testes

```sh
cd ~/caelestia-whatsapp/daemon

go vet ./...
go test ./... -count=1
```

Os testes do pacote `internal/database` usam `t.TempDir()` e cobrem migração
idempotente, presença de tabelas/índices em `sqlite_master`, pragmas
(`foreign_keys`, `journal_mode`, `busy_timeout`), violação de FK e permissão
`0600` do arquivo (Linux). A fase 2.4 acrescenta:

- `internal/database/repo_test.go`: idempotência de `InsertMessage`, ordenação e
  paginação de chats/mensagens, contadores de não lidas, `before`, recibos,
  contatos e `cae_sync_state`.
- `internal/whatsapp/persist_test.go`: pipeline de eventos (mensagem, recibo,
  histórico, contato/grupo) sobre um DB temporário e *seams* falsos.
- `internal/whatsapp/methods_test.go`: handlers com `client` fake + DB
  temporário (`chats.list`, `chat.messages`, `message.send/reply/read`,
  `contacts.search` e os códigos de erro `not_paired`/`invalid_request`).

A CLI é validada apenas com `go build`/`go vet` (não tem testes de rede):

```sh
cd ~/caelestia-whatsapp/cli/cwctl
go build ./...
go vet ./...
```

## Rodar o daemon

O daemon carrega a configuração, cria os diretórios, abre e migra o SQLite, sobe
o `sqlstore` do whatsmeow, o servidor IPC UDS, o *pump* de eventos e o worker de
persistência (fase 2.4), e espera `SIGINT`/`SIGTERM` para encerrar (código de
saída `0`).

```sh
./bin/caelestia-whatsappd \
  --data-dir "$HOME/.local/share/caelestia-whatsapp" \
  --socket   "${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock" \
  --log-level info
```

### Flags

| Flag | Default | Descrição |
|---|---|---|
| `--data-dir` | `${XDG_DATA_HOME:-~/.local/share}/caelestia-whatsapp` | diretório do `whatsapp.db` e do `cache/` |
| `--socket` | `${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock` | caminho do Unix domain socket |
| `--log-level` | `info` | `debug`, `info`, `warn` ou `error` |

As variáveis `XDG_DATA_HOME` e `XDG_RUNTIME_DIR` só definem os **defaults**; uma
flag explícita sempre vence.

## CLI `cwctl` (módulo separado)

A CLI é um **módulo Go próprio** (`cli/cwctl/go.mod`, módulo
`github.com/stoltembergg-png/caelestia-whatsapp/cli/cwctl`) e **não** importa o
módulo do daemon: ela fala NDJSON cru no socket UDS. Isso mantém o contrato
IPC como a única dependência entre os dois.

```sh
cd ~/caelestia-whatsapp/cli/cwctl
go build -o cwctl .
```

Se o socket default não estiver no `PATH`, passe `--socket`:

```sh
export SOCK="${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock"

./cwctl --socket "$SOCK" status                     # estado da conexão/auth
./cwctl --socket "$SOCK" chats --limit 20           # lista conversas
./cwctl --socket "$SOCK" messages "$JID" --limit 50 # histórico
./cwctl --socket "$SOCK" send "$JID" "olá!"         # envia texto
./cwctl --socket "$SOCK" login                      # imprime o QR e aguarda
./cwctl --socket "$SOCK" logout                     # desvincula
```

Comportamento:

- `--socket` pode vir antes ou depois do subcomando (default
  `$XDG_RUNTIME_DIR/caelestia-whatsapp.sock`).
- Cada request tem timeout (10 s; envio/logout 30 s).
- Saída legível (tabela de conversas, mensagens em ordem cronológica).
- Erro ⇒ mensagem no `stderr` e **exit code ≠ 0**; o código estável do erro
  (`not_paired`, `not_found`, `send_failed`, …) aparece no início da mensagem.
- `login [--timeout 2m]` renderiza cada `auth.qr` no terminal (via
  `github.com/mdp/qrterminal/v3`) e bloqueia até `auth.connected` ou o
  timeout; **não** pareia sozinho. Interrompa com `Ctrl+C`.
- A CLI nunca lê/grava o banco nem vê credenciais: só o socket `0600`.

## Instalar como serviço de usuário

O `scripts/install.sh` é um instalador **local, idempotente e sem `sudo`**:
compila o daemon e a CLI para `~/.local/bin/`, cria o diretório de dados
`~/.local/share/caelestia-whatsapp/` (`0700`) e instala o unit em
`~/.config/systemd/user/caelestia-whatsapp.service`, rodando
`systemctl --user daemon-reload` ao final. Ele **não** habilita nem inicia o
serviço automaticamente — imprime os comandos para você decidir.

```sh
cd ~/caelestia-whatsapp
scripts/install.sh
```

Se `~/.local/bin` não estiver no `PATH`, exporte antes de usar `cwctl`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Em HOME alternativo (testes/CI), a instalação fica contida no HOME informado:
`HOME=/tmp/cw-install-test scripts/install.sh` compila, copia binários e
instala o unit sob `/tmp/cw-install-test`, usando o cache de módulos do home
real para não baixar as dependências de novo.

### Habilitar, iniciar e verificar

```sh
systemctl --user enable --now caelestia-whatsapp.service

systemctl --user status caelestia-whatsapp.service
journalctl --user -u caelestia-whatsapp.service -f

cwctl status                      # state: needs_pairing (antes do login)
cwctl login                       # imprime o QR e aguarda o pareamento
```

A unit usa `ExecStart=%h/.local/bin/caelestia-whatsappd`, `Type=simple`,
`Restart=on-failure`, `RestartSec=2` e `WantedBy=default.target`; **não** há
segredos em `Environment=` (a sessão vive no SQLite `0600`). O daemon roda sem
o shell e o frontend QML reconecta sozinho se ele reiniciar.

### Socket activation (opcional/experimental)

`systemd/caelestia-whatsapp.socket` (`ListenStream=%t/caelestia-whatsapp.sock`,
`SocketMode=0600`, `Accept=no`, `WantedBy=sockets.target`) está no repositório
apenas como referência. O daemon **atual não implementa** socket activation:
ele não lê o FD passado pelo systemd (`go-systemd/v22/activation`) e ainda
cria/remove o socket por conta própria, o que conflita com o unit. Portanto:

- **Modo padrão e suportado:** serviço ativo (`caelestia-whatsapp.service`).
- **Não** habilite o `.socket` junto com o `.service`.
- O `.socket` vira suportado quando o daemon adotar `activation.Listeners()`.

Veja [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) para falhas comuns (socket,
`not_paired`, QR, 405, ban, logs, reset de sessão).

## Teste manual do fluxo completo (smoke)

Com o daemon e a CLI compilados, um smoke que cobre status, erro sem sessão e
QR:

```sh
SMOKE="$(mktemp -d /tmp/cw-smoke.XXXXXX)"
SOCK="$SMOKE/caelestia-whatsapp.sock"
./caelestia-whatsappd --data-dir "$SMOKE/data" --socket "$SOCK" --log-level debug &
DPID=$!
until [ -S "$SOCK" ]; do sleep 0.1; done

./cwctl --socket "$SOCK" status          # estado: needs_pairing
./cwctl --socket "$SOCK" chats           # erro not_paired (exit != 0)
./cwctl --socket "$SOCK" login --timeout 25s   # imprime o QR e sai no timeout

kill -TERM "$DPID"; wait "$DPID"
```

## Teste manual (smoke) do daemon

Sobe o daemon apontando para um diretório temporário, envia `SIGTERM` após
~2 s e verifica o log e as permissões:

```sh
cd ~/caelestia-whatsapp/daemon
mkdir -p bin
go build -o bin/caelestia-whatsappd ./cmd/caelestia-whatsappd

DATADIR="$(mktemp -d /tmp/caelestia-whatsapp-test.XXXXXX)"
rm -rf "$DATADIR"          # deixa o daemon criar (prova o MkdirAll)

./bin/caelestia-whatsappd --data-dir "$DATADIR" --log-level debug &
PID=$!
sleep 2
kill -TERM "$PID"
wait "$PID"; echo "exit=$?"

stat -c '%a %n' "$DATADIR" "$DATADIR/cache" "$DATADIR/whatsapp.db"
```

Saída esperada (resumo):

```
time=... level=INFO msg="caelestia-whatsappd starting" version=0.1.0-dev ...
time=... level=INFO msg="database ready" path=/tmp/.../whatsapp.db
time=... level=INFO msg="ready; waiting for shutdown signal"
time=... level=INFO msg="shutdown signal received" signal=terminated
time=... level=INFO msg="shutdown complete"
exit=0
700 /tmp/.../caelestia-whatsapp-test.XXXXXX
700 /tmp/.../caelestia-whatsapp-test.XXXXXX/cache
600 /tmp/.../caelestia-whatsapp-test.XXXXXX/whatsapp.db
```

## Estrutura de dados criada

```
<data-dir>/            (0700)
├── whatsapp.db        (0600, WAL + foreign_keys)
├── whatsapp.db-wal    (0600, quando existir)
├── whatsapp.db-shm    (0600, quando existir)
└── cache/             (0700)
```

Tabelas `cae_*`: `cae_schema_version`, `cae_accounts`, `cae_chats`,
`cae_contacts`, `cae_groups`, `cae_messages`, `cae_receipts`, `cae_media`,
`cae_sync_state`. As tabelas `whatsmeow_*` serão gerenciadas pelo `sqlstore`
em um passo futuro e **nunca** devem ser renomeadas.

## Solução de problemas

- **`go: command not found`** — garanta `~/.local/bin` no `PATH`.
- **Permissão do DB diferente de `0600`** — o daemon faz `chmod` no arquivo e
  nos sidecars WAL/SHM; se um `whatsapp.db` pré-existente tiver permissão
  larga, rode novamente (o `Open` corrige) ou apague o arquivo.
- **`database is locked`** — não deve ocorrer: o pool é limitado a uma conexão
  (`SetMaxOpenConns(1)`) e há `busy_timeout=10000`.
- **`log-level` inválido** — o processo sai com código `1` e mensagem
  `logging: invalid log level ...`.

## Privacidade

Logs nunca devem conter chaves, tokens, material de sessão ou credenciais. Use
os helpers de `internal/logging` (`RedactJID`, `RedactPhone`, `RedactAttr`)
ao logar identificadores. O socket e o banco são restritos ao dono
(`0600`/`0700`), e não há HTTP/TCP nesta fase.
