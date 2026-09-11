# Integração no Caelestia

Este repo adiciona ao [Caelestia Shell](https://github.com/caelestia-dots/shell) quatro extras portados do [Serpantinum](https://github.com/ilyamiro/serpantinum):

- **Quick Actions** — overlay por borda com **Notas** e **Lousa** (`DrawAction`).
- **Dock** — dock de apps com autohide, hover-magnify, reorder, app-picker e strip de minimizados.
- **No Limits** — motor de quotas (KodexBar) + ai-memory, popup com 4 abas, notificações; cápsula opcional na barra.
- **WhatsApp** — painel WebEngine com sessão persistida, tema integrado e gestão de RAM.

Requisitos: Caelestia (fork clonado) em `~/.config/quickshell/caelestia` e **Quickshell git master**. O WhatsApp exige o **build patchado com WebView** e o wrapper `qs` (instalados pelo `install.sh`; build em `scripts/build-quickshell-webview.sh`).

## Instalação

```bash
git clone https://github.com/stoltembergg-png/caelestia-extras.git
cd caelestia-extras
./scripts/build-quickshell-webview.sh    # se ainda não tiver ~/.local/opt/quickshell-webview
./install.sh                             # ou: ./install.sh /caminho/do/quickshell/caelestia
```

O `install.sh` (idempotente, com backups):
1. copia `src/extras/` para `$CAELESTIA_DIR/extras`;
2. insere `Loader { source: "extras/Extras.qml"; asynchronous: true }` no `shell.qml`;
3. adiciona `//@ pragma EnableQtWebEngineQuick` no topo do `shell.qml` (WhatsApp);
4. instala o wrapper `scripts/qs` em `~/.local/bin/qs` (usa o build patchado; fallback `/usr/bin/qs`);
5. aplica o patch opcional da barra (`scripts/patch-caelestia-bar.py`: `DelegateChoice` + entrada no `shell.json`);
6. migra estado/settings do Serpantinum (`scripts/migrate-serpantinum.sh`).

> Se o Caelestia foi instalado via CMake (e não clonado como fork), o CMake não copia `extras/`. Rode o shell a partir do fork em `~/.config/quickshell/caelestia`.

## Atalhos (Hyprland)

`GlobalShortcut` com `appid: "caelestia"` e nomes `quickactions`, `dock`, `nolimits`, `whatsapp`.

```lua
hl.bind("SUPER + N", hl.dsp.global("caelestia:quickactions"))
hl.bind("SUPER + D", hl.dsp.global("caelestia:dock"))
hl.bind("SUPER + K", hl.dsp.global("caelestia:nolimits"))
hl.bind("SUPER + W", hl.dsp.global("caelestia:whatsapp"))
```

Config clássica: `bind = SUPER, N, global, caelestia:quickactions` (idem para as demais). O Quick Actions também abre por **hover de borda**.

## IPC

```bash
qs -c caelestia ipc call extras toggleQuickActions
qs -c caelestia ipc call extras setQuickActionsTab 1        # 0 = Notas, 1 = Lousa
qs -c caelestia ipc call extras toggleDock
qs -c caelestia ipc call extras toggleNoLimits
qs -c caelestia ipc call extras setNoLimitsView memory      # limits|memory|activity|settings
qs -c caelestia ipc call extras toggleWhatsApp
# alternativa: caelestia shell extras <função>
```

## Configuração

`~/.config/caelestia/extras.json` (criado com defaults na primeira execução):
- `dock` — position, elementSize, floating, opacity, exclusive, autohide, apps[], hoverScale…
- `noLimits` — display, disabled[], thresholds{}, notify, notifyCooldown, memory (migrado do Serpantinum quando existir).
- `quickactions`/`general`/`display` — escala e comportamento do host.

Estado: `~/.local/state/caelestia/nolimits/{quota-history,events}.json`, `…/notepad/notes.json`, `…/dock/minimized.json`.

## Cápsula do No Limits na barra (opcional)

O `install.sh` já tenta aplicar (`python3 scripts/patch-caelestia-bar.py "$CAELESTIA_DIR"`; use `--dry-run` para pré-visualizar). Ele adiciona `import qs.extras.nolimits` e um `DelegateChoice roleValue: "kodexbar"` no `modules/bar/Bar.qml` (backup `.bak-*`) e a entrada em `bar.entries` do `shell.json` (se existir). Sem isso, o No Limits continua acessível pelo atalho/IPC.

## Desinstalação

```bash
rm -rf "$CAELESTIA_DIR/extras"
# remova os blocos entre >>> / <<< caelestia-extras no shell.qml e o DelegateChoice marcado no Bar.qml
# (ou restaure os backups .bak-*)
```

## Smoke test (obrigatório — validação foi só estática)

1. Reinicie o shell: `qs -c caelestia kill` e suba de novo (com o wrapper `qs` no PATH).
2. `caelestia shell -s` deve listar o target IPC `extras`.
3. **Quick Actions**: atalho abre o overlay; **Notas** cria/edita/salva (`~/.local/state/caelestia/notepad/notes.json`); **Lousa** desenha, undo/redo, zoom/pan, salva PNG e copia.
4. **Dock**: autohide/magnify/reorder/picker. Na 1ª execução fica vazio/invisível: defina `"editing": true` ou adicione apps em `extras.json → dock`.
5. **No Limits**: atalho abre o popup; abas Limits/Memory/Activity/Settings; notificação com ação "Abrir" (via `gdbus`); cápsula na barra se o patch foi aplicado.
6. **WhatsApp**: painel abre, login persiste (`~/.local/share/quickshell/QtWebEngine/serpantinum-whatsapp-v2`), tema acompanha o esquema; `Ctrl+R` recarrega; sem crash de render.
7. Sem erros de QML no log (`journalctl --user -f` ou log do `qs`).

Se algo falhar, os pontos prováveis: shim `ThemeBackend` (tokens), `StyledWindow`/`WlrLayershell` nos hosts, caminhos em `Caching`, e — no WhatsApp — o pragma/wrapper `qs` (build patchado).

## Licença

AGPL-3.0. Componentes derivados do Serpantinum (AGPL-3.0); combinados com o Caelestia (GPL-3.0), a distribuição combinada deve atender à AGPL-3.0. O patch do Quickshell deriva do upstream (GPL-3.0).
