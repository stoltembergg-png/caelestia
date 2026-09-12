# caelestia-whatsapp — contexto do projeto

Integração **nativa** do WhatsApp para o Caelestia Shell: daemon Go (`whatsmeow`) + frontend QML/Quickshell via Unix Domain Socket. Sem WebView, sem Chromium, sem Electron, sem automação de browser.

> **Documento principal:** [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) — análise do Caelestia, arquitetura proposta, fluxos, schema, roadmap e critérios de aceitação do MVP.
>
> Outros docs: [`docs/IPC.md`](docs/IPC.md) (protocolo do socket), [`docs/BUILD.md`](docs/BUILD.md) (compilar/instalar), [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) (diagnóstico).

## Status

**Fase 2 concluída**: daemon + IPC + CLI + systemd.

- **2.1** scaffold Go, config/logging, SQLite versionado (`cae_*`) e testes.
- **2.2** servidor IPC UDS NDJSON (protocolo, limites, peer-UID, broadcast).
- **2.3** cliente `whatsmeow`, QR/login, máquina de estados e pump de eventos (`auth.*`).
- **2.4** repositório, pipeline de eventos, métodos IPC e `cwctl` (QR no terminal).
- **2.5** systemd user service, instalador local sem `sudo` e documentação.

O frontend QML/Quickshell (fases 3+) ainda não foi implementado; o daemon roda
independente do shell.

## Aviso

`whatsmeow` é uma implementação **não oficial** do protocolo WhatsApp. O uso pode violar os Termos de Serviço do WhatsApp e levar a restrição/ban da conta. O projeto **não** implementa automação de envio em massa/scraping; o desenho é de um cliente pessoal de mensagens. Use por sua conta e risco (veja [`TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) §7).

## Quickstart

Requisitos: Linux com systemd de usuário (session manager), Go 1.26+ no `PATH`
(e driver SQLite Go puro; **sem CGO**) e o WhatsApp no celular para parear.

```sh
# 1. Clonar e instalar (local, sem sudo):
git clone https://github.com/stoltembergg-png/caelestia-whatsapp.git
cd caelestia-whatsapp
scripts/install.sh

# 2. Garantir ~/.local/bin no PATH (se necessário):
export PATH="$HOME/.local/bin:$PATH"

# 3. Habilitar e iniciar o daemon (o instalador NÃO faz isso sozinho):
systemctl --user enable --now caelestia-whatsapp.service
cwctl status

# 4. Parear (imprime o QR no terminal; escaneie no WhatsApp):
cwctl login

# 5. Usar:
cwctl status
cwctl chats --limit 20
cwctl messages '<jid>' --limit 50
cwctl send '<jid>' 'olá!'
cwctl logout
```

Logs do daemon:

```sh
journalctl --user -u caelestia-whatsapp.service -f
```

Detalhes de build/flags em [`docs/BUILD.md`](docs/BUILD.md); problemas comuns
em [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md).

## Estrutura de diretórios

Repositório:

```
caelestia-whatsapp/
├── daemon/               # Go: daemon (whatsmeow, IPC UDS, SQLite)
│   └── cmd/caelestia-whatsappd/main.go
├── cli/cwctl/            # Go: CLI (módulo separado, fala NDJSON no socket)
├── systemd/              # caelestia-whatsapp.service (+ .socket experimental)
├── scripts/install.sh    # instalador local, idempotente e sem sudo
├── docs/                 # ARQUITETURA.md, IPC.md, BUILD.md, TROUBLESHOOTING.md
└── README.md
```

Instalado em runtime (tudo do usuário, sem `sudo`):

```
~/.local/bin/caelestia-whatsappd           # daemon
~/.local/bin/cwctl                         # CLI
~/.config/systemd/user/caelestia-whatsapp.service
~/.local/share/caelestia-whatsapp/         # 0700
├── whatsapp.db                            # 0600 (cae_* + whatsmeow_*)
└── cache/                                 # mídia/avatares (fases futuras)
$XDG_RUNTIME_DIR/caelestia-whatsapp.sock   # 0600, criado pelo daemon
```

A sessão do WhatsApp vive no SQLite `0600`; o socket e o banco são restritos ao
dono. Sem HTTP/TCP.

## Limitações conhecidas

- **Sem mídia e sem recursos avançados de grupos** ainda (download/envio de
  imagens, áudio, documentos, reações, reply, busca, etc. são fases 3+). O
  histórico e os eventos de domínio (`message.received`, `receipt.updated`, …)
  são persistidos, mas ainda **não** são publicados no IPC.
- **Sem frontend QML**: não há painel/badge no shell Caelestia nesta fase.
- **`whatsmeow` é não oficial** e viola os ToS do WhatsApp; há risco de
  restrição/ban. Use uma conta que você aceita perder e sem automação.
- **`whatsmeow` sem releases estáveis**: versões fixadas por commit; podem
  ocorrer erros `405`/`client outdated` até atualizar o pin.
- **Socket activation é experimental**: o daemon não lê o FD do systemd; o modo
  suportado é o serviço ativo. Não habilite o `.socket` junto do `.service`.
- **Licença ainda a definir** (ver abaixo).

## Licença

A definir (sugestão: AGPL-3.0, compatível com o ecossistema Caelestia/Quickshell e com o MPL-2.0 do whatsmeow).
