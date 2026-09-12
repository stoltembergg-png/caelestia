# BUILD — compilar, testar e rodar o daemon

Este documento cobre **somente o backend Go** (`daemon/`). O shell (QML), o
systemd e a CLI são passos posteriores.

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
`0600` do arquivo (Linux).

## Rodar o daemon

Neste passo o daemon apenas carrega a configuração, cria os diretórios, abre e
migra o SQLite, loga o *startup* e espera `SIGINT`/`SIGTERM` para encerrar
(código de saída `0`). **Ainda não há IPC nem whatsmeow.**

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
| `--socket` | `${XDG_RUNTIME_DIR:-/tmp}/caelestia-whatsapp.sock` | caminho do Unix domain socket (reservado para o passo de IPC) |
| `--log-level` | `info` | `debug`, `info`, `warn` ou `error` |

As variáveis `XDG_DATA_HOME` e `XDG_RUNTIME_DIR` só definem os **defaults**; uma
flag explícita sempre vence.

## Teste manual (smoke)

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
