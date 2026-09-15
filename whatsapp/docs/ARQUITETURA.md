# caelestia-whatsapp — Documento Técnico (Fase 1)

Integração nativa do WhatsApp para o **Caelestia Shell**: daemon Go + frontend QML/Quickshell via **Unix Domain Socket**. Sem WebView, Chromium, Electron, iframe ou automação de browser.

Base de evidências: core instalado `~/.config/quickshell/caelestia` (com os patches extras) e clone do fork em `~/Documents/Codex/2026-09-04/na/work/caelestia-shell` (HEAD `750e67d`); o snapshot upstream `d8ee1e8` foi a referência de projeto; pesquisas de whatsmeow e Quickshell IoSocket (set/2026); implementações já feitas no repo `caelestia-extras` (dock nativa, drawer, No Limits) que servem de precedente congelado.

---

## 1. Análise da arquitetura atual do Caelestia

### 1.1 Estrutura geral
`shell.qml` (entry, `ShellRoot`) → `Drawers` (janela layer-shell full-screen `caelestia-drawers`) + `Shortcuts` + `BatteryMonitor` etc. Diretórios:

| Diretório | Papel |
|---|---|
| `modules/` | UI de alto nível: `bar/`, `launcher/`, `dashboard/`, `sidebar/`, `utilities/`, `notifications/`, `osd/`, `session/`, `lock/`, `nexus/`, `drawers/`, `background/`, `areapicker/`, `windowinfo/` |
| `services/` | Singletons QML: `Colours`, `Hypr`, `ShellState`, `Screens`, `Notifs`/`NotifData`, `Audio`, `Brightness`, `Wallpapers`, `Players`, `Time`, `SysInfo` |
| `components/` | `controls/` (`ButtonBase`, `IconButton`, `StyledTextField`, `Menu`…), `containers/` (`StyledWindow`, `StyledListView`, `VerticalFadeListView`…), `widgets/`, `misc/` (`CustomShortcut`), `effects/` (`Elevation`, `Mask`, `Colouriser`), `images/` |
| `utils/` | `Paths`, `Icons`, `Images`, `SysInfo`, `Strings`, `Searcher` |
| `plugin/` | Plugin C++ Qt6 (`Caelestia.*`): Config/Services/Models/Blobs/Dialogs… — config schema fica **em C++** |
| `assets/`, `scripts/` | fontes/ícones; scripts |
| `extras/` | pasta de módulos externos carregada por `Loader` no `shell.qml` (nosso padrão) |

### 1.2 Tema, tokens e animação
- `Colours.palette.m3*` (conteúdo) e `Colours.tPalette.m3*` (superfícies com transparência do usuário) + `Colours.layer()/on()`.
- `Tokens.*` (attached C++, `import Caelestia.Config`): `rounding/spacing/padding.{extraSmall…extraExtraLarge}`, `font.{headline,title,body,label,mono,icon}.{large,medium,small}`, `anim.{standard,emphasized,expressive*}` + `anim.durations.*`, `sizes.{bar,utilities,sidebar,…}`.
- `Anim { type: Anim.FastSpatial|DefaultSpatial|… }` para animações M3; `Behavior`+`Anim` é o padrão.
- Config: `~/.config/caelestia/shell.json` com **schema C++** (chaves desconhecidas são quarentenadas — não expostas ao QML). Tokens em `shell-tokens.json`. Módulos externos usam JSON próprio (nosso `extras.json`).

### 1.3 Drawers, painéis e o “aro”
- `modules/drawers/ContentWindow.qml`: janela layer-shell única por tela (`ExclusionMode.Ignore`), contém `BlobGroup` + `BlobInvertedRect` (o **aro** da tela: espessura `Config.border.thickness=10`, raio 25, smoothing 20) e um `PanelBg` (BlobRect) por painel — os painéis **fundem-se** ao aro (sink do shader).
- `Panels.qml`: instancia os painéis (`Wrapper`s) ancorados (launcher centro-inferior, utilities direita-inferior, sidebar direita, dashboard topo…). Cada painel expõe `offsetScale` (0 visível/1 oculto), `transform` (matriz de deformação) e `implicitWidth/Height`.
- `Regions.qml`: máscara de input (Xor na raiz + `R` por painel); sem uma `R` o painel não recebe cliques.
- `Exclusions.qml`: janelas `border-exclusion` que reservam espaço (barra e dock).
- `Interactions.qml`: hover/scroll/popouts; `checkPopout(y)` abre popouts da barra; `inLeftPanel/inRightPanel/…`.
- Precedentes nossos: a **dock nativa** e o **drawer do WhatsApp** já usam esse modelo com patches idempotentes (`scripts/patch-caelestia-dock.py`, `patch-caelestia-whatsapp.py`).

### 1.4 Barra
- Vertical (`ColumnLayout`), dirigida por dados: `Config.bar.entries` (lista de `{id, enabled}`) + `DelegateChooser` casando `roleValue` por **string livre** (ids custom funcionam sem mudar o schema C++).
- Popouts nativos: `Popouts.Wrapper`/`Content.qml` (nome→conteúdo) + `checkPopout`; usados por tray/statusIcons/activeWindow.
- Precedente nosso: widget `kodexbar` (DelegateChoice via patch) com badge/percentual (`extras/nolimits/NoLimitsBarItem.qml`) — o mesmo mecanismo serve ao **badge de não lidas do WhatsApp**.
- **Limitação do schema**: cada `bar.entries` é um `ListEntry` só com `id`/`enabled` (C++ `common.hpp:34-41`/`barconfig.hpp:111-122`); configuração do módulo vai em `extras.json`, nunca na entry.

### 1.5 Nexus (Ajustes)
- `PageRegistry.qml` (metadados) + `PageCompRegistry.qml` (Component por índice, **mesma ordem**); páginas usam `PageBase`, `SectionHeader`, `ToggleRow`, `SliderRow`, `StepperRow`, `SelectRow`, `NavRow`, `InfoRow`, `ConnectedRect`, `StackPage`.
- Padrão já usado por nós: `DockPage.qml`/`WhatsAppPage.qml` em `extras/settings/` + patch idempotente nos dois registries + fallback standalone (janela própria) caso o patch quebre em updates.

### 1.6 Notificações
- O core **é dono** do servidor `org.freedesktop.Notifications` (`services/Notifs.qml`/`NotifData`) — um módulo externo **não** cria outro servidor.
- Envio a partir de um módulo: `gdbus call org.freedesktop.Notifications.Notify …` (entra no centro de notificações, persiste, respeita DND) com ação “Abrir” via `gdbus monitor … ActionInvoked` — padrão exato já em `extras/nolimits/NoLimits.qml:561-577,971-994`.
- Estado efêmero (conectando/desconectado): `Toaster.toast(...)` do core (`plugin/src/Caelestia/toaster.hpp:61-75`; `import Caelestia`).

### 1.7 Plugin infrastructure
- No `main` **não há** plugin system ativo (Nexus→Plugins é placeholder). O PR **#1703** (aberto, instável; branch `feat/plugins`) define `manifest.json` + `entryPoints` (`bar-entry`, `bar-popout`, `status-icon`, `quick-toggle`, `dashboard-tab`) e busca em `~/.local/share/caelestia/plugins`.
- Estratégia: implementar agora com nosso padrão `extras/` + patches idempotentes, mas **isolando** backend (Go) e contrato IPC — a migração futura para plugin oficial não deve tocar o daemon.

### 1.8 Conclusão — melhor ponto de integração
1. **Backend**: daemon independente (`caelestia-whatsappd`), systemd user service — roda sem o shell.
2. **Ponte QML**: singleton em `extras/services/WhatsApp.qml` usando **`Quickshell.Io.Socket` + `SplitParser`** (existe nativo; `SOCKETS=ON` por padrão), com wrapper de reconexão/backoff.
3. **UI**: painel nativo no estilo da dock/drawer (blob/aro) + badge na barra (patch da entries) + página no Nexus (patches nos registries) + notificações via `gdbus`.
4. **CLI**: `cwctl` (cliente UDS fino) para testar/operar sem o shell.

---

## 2. Arquitetura final proposta

```
┌─────────────────────────────── Caelestia Shell (QML/Quickshell) ──────────────────────────────┐
│ extras/services/WhatsApp.qml  ← Socket UDS JSONL (DankSocket-like: backoff, fila, id→cb)      │
│ extras/modules/whatsapp/{ChatList,ChatView,MessageBubble,MessageComposer,LoginView,…}          │
│ Barra: DelegateChoice "whatsapp" (badge unread)   Nexus: página WhatsApp                        │
└───────────────────────────────────────▲────────────────────────────────────────────────────────┘
                                        │ $XDG_RUNTIME_DIR/caelestia-whatsapp.sock (0600, JSONL)
┌───────────────────────────────────────▼────────────────────────────────────────────────────────┐
│ caelestia-whatsappd (Go, systemd user service, sem shell)                                      │
│  ipc (server UDS, JSON-RPC por linha, eventos)   whatsapp (whatsmeow client + handlers)        │
│  database (SQLite: cae_* + whatsmeow_* via sqlstore)   media (download/cache/thumbs)           │
│  contacts/groups sync   notifications (eventos p/ o shell)   logging (sem segredos)            │
└──────────────────────────────────────────────────┬─────────────────────────────────────────────┘
                                                   │ whatsmeow (WebSocket)
                                        ~/.local/share/caelestia-whatsapp/whatsapp.db + cache/
```

### 2.1 Backend (Go)
- **`cmd/caelestia-whatsappd`**: wiring, flags (`--socket`, `--data-dir`, `--log-level`), sinais, systemd notify opcional.
- **`internal/whatsapp`**: cliente whatsmeow; handlers de eventos → canal interno; envio (texto/reply/reação/read); presença/typing; reconexão e tratamento de eventos permanentes.
- **`internal/ipc`**: servidor UDS; JSON-RPC por linha; `subscribe` implícito (mesma conexão recebe eventos) ou método dedicado; validação de payload; limites.
- **`internal/database`**: SQLite (driver `modernc.org/sqlite`, WAL/FK/busy_timeout); migrações `cae_*` + `sqlstore.Upgrade()` no boot; repositórios.
- **`internal/media`**: download sob demanda com worker pool/semáforo; escrita em cache; thumbnails; `DownloadToFile` p/ grandes.
- **`internal/contacts`**: contatos/grupos/avatares; nomes preferenciais (contact > push > phone).
- **`internal/notifications`**: monta payloads de notificação (o envio real é do shell) e emite eventos relevantes.

> Ponte QML: `Quickshell.Io.Socket` (existe em `quickshell-io.qmltypes:195-243`: `path`, `connected`, `write()`, `flush()`, `error`, base `DataStream` com `parser`) + `SplitParser { onRead }` para NDJSON. Sem `socat`/`nc`.
- Regras: handlers de eventos **não bloqueiam** (copiam e enfileiram); persistir antes de publicar; mídia nunca inline no IPC (apenas caminho/metadados).

### 2.2 Frontend (QML)
- `services/WhatsApp.qml` (singleton em `extras/`): conexão UDS, `id→callback`, fila pré-conexão, backoff, heartbeat; expõe `ListModel`s (chats/mensagens) e estado de conexão/auth; nunca vê credenciais.
- `modules/whatsapp/`: `LoginView` (QR string → render), `ChatList`, `ChatView`, `MessageBubble`, `MessageComposer`, `ContactAvatar`, `MediaPreview`.
- Envelope: IDs e timestamps **como string/número seguro** no wire (evitar perda de precisão > 2^53 no JS).

---

## 3. Fluxos

### 3.1 Lifecycle do daemon
1. `flock` por arquivo de dados (instância única; evita `StreamReplaced`).
2. Abre SQLite (`0600`), roda `sqlstore.Upgrade()` + migrações `cae_*` (falha o start se FK off).
3. `GetFirstDevice()`; se `Store.ID == nil` → estado `NEEDS_PAIRING`.
4. Sobe o servidor UDS (`0600`, em `$XDG_RUNTIME_DIR`), remove socket órfão.
5. `Connect()` (auto-reconnect ligado) + `SendPresence(Available)`.
6. Encerramento: para aceitação, fecha conexões, `Disconnect()`, remove o socket. Logout **não** é automático.

### 3.2 Autenticação (QR)
`auth.start` → `client.GetQRChannel(ctx)` (antes do `Connect`) → loop do canal:
- `{event:"code"}` → `auth.qr {code, timeout}` (1º = 60 s; seguintes = 20 s) → frontend renderiza QR (string).
- `{event:"success"}` (PairSuccess) → sessão salva pelo sqlstore → `auth.connected`.
- `{event:"timeout"/"error"}` → `auth.error {message}` e novo código automaticamente.
- `auth.logout` → `client.Logout()` + apaga device → `NEEDS_PAIRING`.
- Eventos de estado: `auth.connected/disconnected`; `connection.updated {state, since}`.

### 3.3 IPC (JSONL)
Envelope de request: `{"id":<number>,"method":"<ns.verb>","params":{…}}` → resposta `{"id":…,"result":…}` ou `{"id":…,"error":{"code":…,"message":…}}`; eventos: `{"event":"<ns.verb>","data":{…}}`.
- Métodos MVP: `auth.start|status|logout`, `chats.list`, `chat.open`, `chat.messages`, `message.send|reply|react|read`, `contacts.search`, `media.download|media.send`, `presence.typing|presence.available`, `ping`.
- Eventos: `auth.qr|connected|disconnected`, `message.received|updated|deleted`, `receipt.updated`, `chat.updated`, `typing.updated`, `connection.updated`.
- Limites: linha máxima (ex.: **1 MiB** controle; mídia só por caminho), validação de tipos/ranges, rejeitar payload malformado sem panic, timeout de request no cliente, fila de subscrição limitada.

### 3.4 Pipeline de eventos
```
whatsmeow handler (rápido) → copy → chan (buffer 1024)
   → dispatcher: persiste SQLite (fonte da verdade) → monta envelope → publica aos clientes IPC
```
Nunca descartar `Message`/`Receipt`/`HistorySync`; `Presence/ChatPresence` podem ser coalescidos. `SynchronousAck`/`EnableDecryptedEventBuffer` conforme robustez desejada.

### 3.5 Mídia
Download sob demanda via `media.download` → `DownloadToFile` (streaming) em worker com semáforo → cache em `cache/<tipo>/<sha256>.<ext>` + thumbnail → resposta com caminho/metadados (nunca bytes grandes no IPC). Envio: `UploadReader` + mensagem correspondente.

---

## 4. Banco de dados (schema inicial)

- **whatsmeow_***: gerenciado por `sqlstore` (device, sessões, chaves, contatos, LID map, buffers). **Nunca** tocar/renomear. Mesmo arquivo SQLite, version table própria.
- **cae_*** (nossas; prefixo obrigatório):

| Tabela | Campos principais |
|---|---|
| `cae_schema_version` | version (migrações próprias) |
| `cae_accounts` | `device_jid PK`, `push_name`, `platform`, `created_at`, `last_connect_at` |
| `cae_chats` | `jid PK`, `kind` (dm/group), `name`, `last_message_id`, `last_message_ts`, `last_preview`, `unread_count`, `pinned`, `archived`, `mute_until`, `updated_at` |
| `cae_contacts` | `jid PK`, `first_name`, `full_name`, `push_name`, `business_name`, `avatar_id`, `avatar_path`, `updated_at` |
| `cae_groups` | `jid PK`, `name`, `topic`, `participants_json`, `updated_at` |
| `cae_messages` | `id PK` (MessageID), `chat_jid`, `sender_jid`, `from_me`, `timestamp`, `type`, `text`, `quoted_id`, `reaction_to`, `edited`, `deleted`, `server_id`, `status`, `media_id` |
| `cae_receipts` | `message_id`, `user_jid`, `type`, `ts` (PK composta) |
| `cae_media` | `id PK`, `message_id`, `kind`, `mime`, `size`, `path`, `sha256`, `status`, `downloaded_at` |
| `cae_sync_state` | `key PK`, `value` (ex.: `history_done`, `contacts_ts`, `groups_ts`) |

Índices: `cae_messages(chat_jid, timestamp DESC)`, `cae_messages(chat_jid, server_id)`, `cae_chats(last_message_ts DESC)`, `cae_chats(unread_count>0)` (parcial).
Pragmas: `foreign_keys=1`, `journal_mode=WAL`, `busy_timeout=10000`, `synchronous=NORMAL`; escrita serializada (`SetMaxOpenConns(1)` p/ writer). Permissão `0600` no arquivo.

---

## 5. Estrutura de diretórios

```
caelestia-whatsapp/
├── daemon/
│   ├── cmd/caelestia-whatsappd/main.go
│   ├── internal/{whatsapp,ipc,database,media,contacts,notifications}/
│   └── go.mod
├── shell/
│   ├── services/WhatsApp.qml
│   ├── modules/whatsapp/{WhatsAppPanel,ChatList,ChatView,MessageBubble,MessageComposer,ContactAvatar,MediaPreview,LoginView}.qml
│   └── components/whatsapp/…
├── systemd/caelestia-whatsapp.service (+ .socket opcional)
├── cli/cwctl/…
├── docs/{ARQUITETURA.md,IPC.md,DATABASE.md,BUILD.md,TROUBLESHOOTING.md}
├── patches/ (integrações idempotentes no Caelestia: barra/Nexus/painel)
└── README.md
```

Dados: `~/.local/share/caelestia-whatsapp/{whatsapp.db, cache/{avatars,images,videos,audio,documents}, thumbnails/}`.
Socket: `$XDG_RUNTIME_DIR/caelestia-whatsapp.sock` (`0600`). Config não-sensível: `~/.config/caelestia-whatsapp/config.toml` (sem credenciais — a sessão vive no SQLite `0600`; libsecret não é necessária no MVP, podendo ser usada para outros segredos futuros).

---

## 6. Integração com o Caelestia (edição mínima do core)

| Componente | Onde vive | Como integra |
|---|---|---|
| Serviço QML | `shell/services/WhatsApp.qml` + qmldir do extras | carregado pelo `Loader` do nosso `Extras.qml` (sem core) |
| Painel/lista/chat | `shell/modules/whatsapp/` | **reuso integral do plumbing já patcheado** (`patch-caelestia-whatsapp.py`: `Panels.qml`/`ContentWindow.qml`/`Regions.qml`/`Interactions.qml` + `WhatsAppState` + API do Drawer `offsetScale/open/close`); trocar apenas o `Loader` de conteúdo (WebEngine → `WhatsAppChatView` nativa) |
| Badge na barra | patch do `DelegateChooser` em `modules/bar/Bar.qml` + entrada em `bar.entries` | `roleValue:"whatsapp"` mostra ícone + badge de não lidas; clique abre o painel |
| Nexus | `PageRegistry`+`PageCompRegistry` (patch) + `shell/settings/WhatsAppPage.qml` | seção com estado de conexão, QR/login, logout, preferências |
| Notificações | — | `gdbus call org.freedesktop.Notifications.Notify` com ação “Abrir” (monitor de `ActionInvoked`), como no No Limits |
| Fallback | — | janela standalone de Ajustes se o patch do Nexus quebrar |
| CLI | `cwctl` | fala direto no UDS; independe do shell |

Migração futura: quando o plugin system oficial (PR #1703) estabilizar, `shell/services` + `modules/whatsapp` viram um plugin (`manifest.json`, `entryPoints`), **sem tocar no daemon nem no protocolo IPC**.

Obs.: o drawer WebView atual (`caelestia-extras/src/extras/whatsapp/*`) é **substituído** por esta integração; o mesmo contrato visual (blob/aro, animação `offsetScale`, sensor de borda) é reaproveitado.

---

## 7. systemd (user service)

```ini
# ~/.config/systemd/user/caelestia-whatsapp.service
[Unit]
Description=WhatsApp daemon (whatsmeow) para o Caelestia
[Service]
ExecStart=%h/.local/bin/caelestia-whatsappd
Restart=on-failure
RestartSec=2
# sem EnvironmentFile com segredos; sessão no SQLite 0600
[Install]
WantedBy=default.target
```
```sh
systemctl --user enable --now caelestia-whatsapp.service
```
Opção **socket activation** (daemon sobe na 1ª conexão): `caelestia-whatsapp.socket` com `SocketMode=0600`, `Accept=no`, `WantedBy=sockets.target`; no Go, `coreos/go-systemd/v22/activation`. O daemon deve funcionar **sem** o shell aberto (requisito), e o shell deve reconectar sozinho se o daemon reiniciar.

Precedentes no ambiente: `~/.config/systemd/user/ai-memory.service` (`Type=simple`, `Restart=on-failure`, `WantedBy=default.target`) e o autostart do Hyprland (`~/.config/hypr/config/autostart.lua`) que sobe serviços com `hl.exec_cmd("systemctl --user enable --now easyeffects")`. Para o nosso daemon: `hl.exec_cmd("systemctl --user start caelestia-whatsapp")` (o `enable` é one-shot), ou socket activation.

---

## 8. Segurança

- Socket em `$XDG_RUNTIME_DIR` (`/run/user/$UID`, 0700) + `chmod 0600`; sem abstract sockets; verificação opcional de peer via `SO_PEERCRED` (mesmo UID).
- Sem HTTP/TCP. JSONL: linha máxima (1 MiB controle; mídia nunca inline), validação estrita de campos, rejeição de payloads malformados, sem `panic`.
- SQLite e cache `0600`/`0700`; nenhum segredo em logs (redigir JIDs/phones quando apropriado e nunca chaves/tokens); sessão whatsmeow permanece no store (SQLite) — não exportar para o QML.
- Single-instance (`flock`) para evitar `StreamReplaced`; limite de conexões IPC e de subscrições.

---

## 9. Riscos técnicos

1. **whatsmeow sem releases estáveis**: versões por commit; Go 1.26+; breaking changes recentes (`context.Context` em várias APIs). Pin exato + CI.
2. **405 Client outdated**: WhatsApp rejeita a versão do handshake quando a lib envelhece → rotina de atualização; mitigação `GetLatestVersion`/`SetWAVersion` (padrão mautrix).
3. **Banimento**: uso não oficial viola ToS; mitigar com comportamento humano (sem broadcast/automação), aviso na UI; nunca vender “envio em massa”.
4. **Migração PN→LID**: identificadores `@lid`; usar `SenderAlt`/`LID`/`AddressingMode`; não assumir `@s.whatsapp.net`.
5. **History sync**: volume grande; ingerir em lote, persistir idempotente (PK = MessageID), respeitar limites de full sync.
6. **SQLite single-writer**: WAL + busy_timeout + writer único; migrações cuidadosas.
7. **Patches do core** (barra/Nexus/painel): churn do upstream; mitigado por marcadores/backups/scripts idempotentes (padrão já validado no `caelestia-extras`).
8. **Plugin infra imatura**: manter interfaces limpas para migrar sem reescrever.
9. **Wayland/Quickshell**: sem riscos para o socket (API nativa); atenção à latência de animação com listas grandes (usar `StyledListView`/reciclagem e modelos paginados).
10. **Mídia**: limites server-side não documentados; validar por tipo; streaming para arquivos grandes.

---

## 10. Roadmap (fases)

- **F1 — Documento técnico** (este documento). ✅
- **F2 — Daemon + IPC + CLI + testes**: Go module; SQLite (sqlstore + `cae_*`); QR/login; sessão; reconexão; servidor UDS JSONL; `cwctl status|chats|messages|send`; testes unitários (DB/IPC) + integração com device falso.
- **F3 — Serviço QML + lista de chats**: `WhatsApp.qml` (Socket+SplitParser+backoff+fila); `LoginView`/QR; `ChatList` (nome, avatar, última msg, hora, unread); painel nativo.
- **F4 — Conversa**: `ChatView`/`MessageBubble`/`MessageComposer`; envio/recebimento em tempo real; read; receipts; unread; histórico recente (`chat.messages` + on-demand).
- **F5 — Integração e polimento**: badge na barra; página no Nexus; notificações; animações/estados; modo minimalista; documentação e screenshots.

Pós-MVP: reply, reações, mídia (imagens/vídeo/áudio/documentos), voice notes, typing, busca, grupos, favoritos, drag&drop, previews.

---

## 11. Critérios de aceitação do MVP

1. `caelestia-whatsappd` sobe via systemd user service, roda **sem** o shell, mantém-se vivo e reconecta após reboot.
2. Login por QR funcional; sessão persiste; `cwctl status` mostra estado; logout volta a `NEEDS_PAIRING`.
3. `cwctl chats|messages <chat>|send <chat> <msg>` funcionam sem Caelestia; `message.received` chega em tempo real no cliente.
4. UI: lista de chats (nome/avatar/última msg/hora/unread), abrir conversa com histórico recente, enviar texto, receber em tempo real, marcar como lido, indicador de conexão/auth.
5. Notificação do Caelestia ao receber mensagem (com ação “Abrir”); badge de não lidas na barra reflete o contador e zera ao ler.
6. Autenticação: `auth.qr` entrega a string do QR; sucesso → `auth.connected`; erro/timeout tratados sem travar.
7. Segurança: socket 0600 em `XDG_RUNTIME_DIR`, DB 0600, sem segredos em log, payloads inválidos rejeitados, sem HTTP/TCP.
8. Estabilidade: reconexão automática; eventos permanentes (LoggedOut/405/StreamReplaced/TempBan) tratados com estados claros; sem crashes em payloads/eventos malformados.
9. Recursos: daemon ocioso ≤ ~80 MB RSS; sem vazamentos em execução contínua de 24 h (smoke) — meta inicial.
10. Modularidade: backend 100% independente do frontend; contrato IPC versionado/documentado (`docs/IPC.md`).

---

## 12. Decisões abertas

1. **Versão pinada do whatsmeow** e driver SQLite (`modernc` recomendado; `mattn` se CGO aceitável).
2. **Envelope IPC**: JSONL simples (recomendado no MVP) vs gRPC (fase futura, se necessário).
3. **Notificações**: `gdbus` (MVP) vs DBus nativo do Quickshell (avaliar).
4. **Visibilidade do repositório** (público para open source vs privado durante o desenvolvimento).
5. **Remoção do drawer WebView atual** do `caelestia-extras` (após F5) ou manutenção temporária como fallback.
