# Integração no Caelestia

Este repo adiciona ao [Caelestia Shell](https://github.com/caelestia-dots/shell) dois extras portados do [Serpantinum](https://github.com/ilyamiro/serpantinum):

- **Quick Actions** — overlay por borda com **Notas** e **Lousa** (`DrawAction`).
- **Dock** — dock de apps com autohide, hover-magnify, reorder, app-picker e strip de minimizados.

Requisitos: Caelestia (fork clonado) em `~/.config/quickshell/caelestia` e **Quickshell git master**.

## Instalação

```bash
git clone https://github.com/stoltembergg-png/caelestia-extras.git
cd caelestia-extras
./install.sh                      # ou: ./install.sh /caminho/do/quickshell/caelestia
```

O script:
1. copia `src/extras/` para `$CAELESTIA_DIR/extras`;
2. insere um `Loader { source: "extras/Extras.qml"; asynchronous: true }` em `shell.qml` (idempotente, com backup `.bak-<data>`).

### Instalação manual (se preferir)

1. Copie `src/extras/` para `$CAELESTIA_DIR/extras`.
2. Dentro do `ShellRoot` em `$CAELESTIA_DIR/shell.qml`, adicione:
   ```qml
   Loader { source: "extras/Extras.qml"; asynchronous: true }
   ```

> Se o Caelestia foi instalado via CMake (e não clonado como fork), o CMake não copia `extras/`. Rode o shell a partir do fork em `~/.config/quickshell/caelestia`.

## Atalhos (Hyprland)

O módulo declara `GlobalShortcut` com `appid: "caelestia"` e nomes `quickactions` e `dock`.

- **Lua** (`~/.config/caelestia/hypr/hyprland/keybinds.lua` ou equivalente):
  ```lua
  hl.bind("SUPER + N", hl.dsp.global("caelestia:quickactions"))
  hl.bind("SUPER + D", hl.dsp.global("caelestia:dock"))
  ```
- **Config clássica**: `bind = SUPER, N, global, caelestia:quickactions`

O overlay de Quick Actions também abre por **hover de borda**, como no Serpantinum.

## IPC

```bash
qs -c caelestia ipc call extras toggleQuickActions
qs -c caelestia ipc call extras setQuickActionsTab 1   # 0 = Notas, 1 = Lousa
qs -c caelestia ipc call extras toggleDock
# alternativa via CLI:
caelestia shell extras toggleQuickActions
```

## Configuração

O shim de config lê/escreve `~/.config/caelestia/extras.json` (criado com defaults na primeira execução). Principais seções: `dock` (position, elementSize, floating, opacity, exclusive, autohide, apps[], hoverScale, …), `quickactions`/`general`/`display`.

## Desinstalação

```bash
rm -rf "$CAELESTIA_DIR/extras"
# remova o bloco entre // >>> caelestia-extras e // <<< caelestia-extras em shell.qml
# (ou restaure o backup .bak-<data>)
```

## Smoke test (obrigatório — validação foi só estática)

1. Reinicie o shell: `qs -c caelestia kill` e suba de novo.
2. `caelestia shell -s` deve listar o target IPC `extras`.
3. Atalho `caelestia:quickactions` abre o overlay; a aba **Notas** cria/edita/salva e persiste em `~/.local/state/caelestia/notepad/notes.json`.
4. A aba **Lousa** desenha (caneta/borracha), undo/redo, zoom/pan, salva PNG em `~/Pictures` e copia via `wl-copy`.
5. O **Dock** aparece, faz autohide, magnifica no hover, reordena por drag e fixa apps pelo picker.
6. Sem erros de QML no log: `journalctl --user -u caelestia-shell -f` (ou o log do `qs`).

Se algo falhar, os pontos mais prováveis são: tema (`Colours`/`Tokens`) no shim `ThemeBackend`; `StyledWindow`/`WlrLayershell` no host; e caminhos em `Caching`.

## Licença

AGPL-3.0. Os componentes derivam do Serpantinum (AGPL-3.0); combinados com o Caelestia (GPL-3.0), a distribuição combinada deve atender à AGPL-3.0.
