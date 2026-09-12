# caelestia-whatsapp — contexto do projeto

Integração **nativa** do WhatsApp para o Caelestia Shell: daemon Go (`whatsmeow`) + frontend QML/Quickshell via Unix Domain Socket. Sem WebView, sem Chromium, sem Electron, sem automação de browser.

> **Documento principal:** [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md) — análise do Caelestia, arquitetura proposta, fluxos, schema, roadmap e critérios de aceitação do MVP.
>
> Outros docs: [`docs/IPC.md`](docs/IPC.md) (protocolo do socket), [`docs/BUILD.md`](docs/BUILD.md) (compilar/instalar), [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) (diagnóstico).

## Status

**MVP completo (Fases 1–5)**: daemon + IPC + CLI + systemd + **UI QML nativa** + integrações no Caelestia.

- **F1** documento técnico (`docs/ARQUITETURA.md`).
- **F2** daemon Go: scaffold, SQLite (`cae_*` + `whatsmeow_*`), IPC UDS NDJSON, QR/login, eventos, `cwctl`, systemd.
- **F3** UI QML nativa: serviço `WhatsAppClient` (socket/backoff/fila), drawer, lista de chats, conversa, composer e QR — estilo Caelestia.
- **F4** (parcial no MVP) eventos de domínio em tempo real (`message.received/updated`, `receipt.updated`, `chat.updated`), read receipts, nomes resolvidos (contatos/LID/pushname/grupo).
- **F5** badge de não lidas na barra, página “WhatsApp” no Nexus e notificações nativas (`gdbus` + ação “Abrir”).

O daemon roda independente do shell (`systemctl --user`); a UI reconecta sozinha ao socket.

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
  imagens, áudio, documentos, reações, reply, busca, etc. são fases futuras). O
  histórico e os eventos de domínio (`message.received`, `receipt.updated`, …)
  já são persistidos e publicados no IPC em tempo real.
- **Nomes de contatos** dependem do store do whatsmeow (contatos/LID/pushname);
  sem contato salvo, cai num PN formatado (`+55…`).
- **`whatsmeow` é não oficial** e viola os ToS do WhatsApp; há risco de
  restrição/ban. Use uma conta que você aceita perder e sem automação.
- **`whatsmeow` sem releases estáveis**: versões fixadas por commit; podem
  ocorrer erros `405`/`client outdated` até atualizar o pin.
- **Socket activation é experimental**: o daemon não lê o FD do systemd; o modo
  suportado é o serviço ativo. Não habilite o `.socket` junto do `.service`.
- **Licença ainda a definir** (ver abaixo).

## Licença

**AGPL-3.0** (ver [`LICENSE`](LICENSE)). Escolhida por compatibilidade com o ecossistema
Caelestia/Quickshell (GPL/AGPL) e por manter o projeto e derivados abertos; o `whatsmeow` é
MPL-2.0 e pode ser usado como dependência sem alterar esta licença.
