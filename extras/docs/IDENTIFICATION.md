# Identificação: Quick Actions e Dock no Serpantinum, e alvo Caelestia

Fonte analisada: `~/serpantinum/src/quickshell` (upstream `ilyamiro/serpantinum`, **AGPL-3.0**).
Alvo do port: Caelestia Shell `main` @ `d8ee1e8` (2026-09-11).

## 1. Quick Actions (Serpantinum)

### Host
- `quickactions/Floating.qml` (1567 l.) — `Variants` sobre `Quickshell.screens` → um `PanelWindow` por tela.
  - Janela: `WlrLayershell.namespace: "qs-floating-overlay"`, `layer: WlrLayer.Overlay`, `exclusionMode: Ignore`, `color: transparent`; anchors full-screen; `focusable` depende do estado/hover.
  - Abertura/fechamento por **hover de borda**: `mask: Region { 8 retângulos de borda + peek + AABB }` + `MouseArea`s (`815-922`) + `handleEdgeEntered/PositionChanged/Exited` (`136-163`); timers `peekHideTimer`/`hideTimer` (`684-799`).
  - **Sem** `GlobalShortcut`, tecla do Hyprland ou `handleCommand`; controle apenas por IPC próprio: `quickshell ipc call floating setIndex <n>` / `showSystemUsage` (`singletons/widgetcontrols/FloatingController.qml:29-43`, `Floating.qml:248-262`).
  - Abas: `tabModules` (`239-244`) → `["actions/DrawAction.qml","actions/SystemUsage.qml","actions/Timer.qml","actions/Notepad.qml"]`.
  - Contrato injetado nos módulos (`1241-1246`): `scaleFunc`, `mochaColors: ThemeBackend`, `activeEdge`, `panelChromeLength`, `isCurrentTarget`; tamanho vem de `preferredWidth` / `preferredExtraLength` / `requestedLayoutTemplate` (`1247-1268`).
  - Ativação: `Shell.qml:48-51` — `Floating {}` sob `!performanceMode && quickactionsEnabled`.

### Módulos de ação (`quickactions/actions/`)
- `Notepad.qml` (420 l.) e `NotesList.qml` (343 l.) — UI de notas.
- `DrawAction.qml` (1170 l.) — **a "lousa"**: canvas infinito 2048×2048 (`Canvas`, `renderTarget: FramebufferObject`), pen/brush/fill/eraser, picker HSVA, paletas, undo/redo, zoom/pan, salvar PNG / `wl-copy` (`560-580`).
- Fora do escopo deste port: `Timer.qml`, `SystemUsage.qml` e o mini-dock órfão `actions/Dock.qml`.

### Notas — duas camadas
- **View portável:** `Notepad.qml` + `NotesList.qml`.
- **Estado:** `singletons/NotesManager.qml` (372 l.) — `ListModel`, persistência em `notes.json` (`Caching.getStateDir("notepad")`), render Markdown via `scripts/notepad/md_render.py` com fallback Qt (`useQtFallback`, `Notepad.qml:313-317`), debounce de 400 ms.

### Acoplamentos a resolver
`ThemeBackend` (cores/borderRadius/font), `Scaler` (`baseScale`, `s()`), `Config` (`getSetting("general"/"bar"/"dock"/"display")`, `rawSettings`), `Caching` (state/run/qs/serpantinum dirs), `I18n`, `SysData` (prewarm), `FloatingController`, `reusables/{IconButton,ClickButton,DeleteButton}`; externos: `xdg-user-dir`, `notify-send`, `wl-copy`, `python3`.

> "Lousa"/whiteboard **não existe** como nome no Serpantinum; o equivalente funcional é `DrawAction`.

## 2. Dock (Serpantinum)

- `dock/Dock.qml` — **monólito de 2029 l.**:
  - `Variants` + `PanelWindow` de exclusão (`qs-dock-exclusion`) e janela `qs-dock` (`WlrLayer.Top`).
  - autohide/reveal (`352-378`); modelo de apps fixos (`380-480`); app-picker via `DesktopEntries` (`512-620`); reveal e hover-magnify (`853-903`, `1278-1615`); `minimizedStrip` lendo `$QS_RUN_DIR/minimized.json` (`1617-1736`, via `scripts/minimize.sh`, workspace `special:minimized`); picker de edição (`1738-2029`).
- Registro/ativação: `qmldir:1` (`Dock 1.0 dock/Dock.qml`); `Shell.qml:27-30` (`Loader { active: dockEnabled }`); config `settings.json:180-231` (`Config.rawSettings.dock`); UI de settings em `guide/DockTab.qml`.
- Acoplamentos: `Config` (forte — `rawSettings.dock`/`bar`), `ThemeBackend`, `Scaler`, `Caching`, `Sounds`, `I18n`, `OsdController.isFullscreen`, `reusables/{Input,ClickButton}`, `minimize.sh` e regras de layout presas à barra (`sameSideAsBar`, `barOffset`, `barStyle`).

## 3. Veredito de modularidade

- **Quick Actions: MÉDIA.** Módulos de ação têm contrato limpo; o host é inseparável do modelo de overlay por borda → exige *re-host*.
- **Dock: BAIXA.** Arquivo único combina janela, modelo, picker, drag-reorder, animações, autohide e min-strip → refactor com injeção de config/tema/escala.

## 4. Alvo Caelestia (`main` @ d8ee1e8)

- Quickshell (QML/Qt6) + plugin C++ (`Caelestia`) sobre Hyprland; Quickshell **git master** é obrigatório.
- Estrutura: `shell.qml`; `modules/` (bar, launcher, dashboard, sidebar, utilities, notifications, osd, drawers...); `services/` (`Colours`, `Hypr`, `ShellState`, `Screens`, ...); `components/` (`controls`, `containers`, `widgets`, `misc`); `utils/` (`Paths`, `Icons`, `SysInfo`); `plugin/` (Config/Settings/Services/Models/...); `assets/`, `extras/`, `scripts/`.
- **Config:** `~/.config/caelestia/shell.json` com schema definido em C++; **chaves desconhecidas são quarentenadas** (não expostas ao QML). Módulos externos devem usar **JSON próprio**.
- **Não há dock** e **não há sistema de plugins ativo** (Nexus→Plugins é placeholder; PR #1703 ainda aberto). Rota robusta: **fork** em `~/.config/quickshell/caelestia`.
- **Tema:** `Colours.palette.m3*` + `Tokens.*`; usar os componentes nativos para não destoar.
- **IPC:** `IpcHandler { target: ... }` → `qs -c caelestia ipc call <target> <fn>` / `caelestia shell <target> <fn>`. Targets ocupados: `drawers`, `nexus`, `toaster`, `audio`, `brightness`, `gameMode`, `hypr`, `idleInhibitor`, `notifs`, `mpris`, `wallpaper`, `colours`, `weather`.
- **Atalhos globais:** `CustomShortcut { name: "..." }` (GlobalShortcut com appid `caelestia`) + bind Hyprland `hl.dsp.global("caelestia:<name>")`.
- **Overlay:** `PanelWindow` por tela via `Screens.screens`, `WlrLayer.Overlay`, `ExclusionMode.Ignore` (mesmo padrão do `ContentWindow.qml`).
- **Pontos de integração no fork:** `shell.qml` (Loader do extras), `modules/Shortcuts.qml` (IPC + atalho); opcionalmente `modules/drawers/*` se integrado ao morphing.

## 5. Plano de port

1. Camada `compat/`: `ThemeBackend`→`Colours`/`Tokens`, `Scaler`, `Config`→JSON próprio, `Caching`→`Paths`, `I18n`, `Sounds`, `SysData`/`FloatingController` mínimos.
2. Quick Actions: host nativo (atalho global + IPC `quickactions`), Notas e Lousa sobre a camada.
3. Dock nativo: overlay `PanelWindow` por tela alimentado por `Hypr.toplevels`/`workspaces`; refatorar o monólito em subcomponentes.
4. `install.sh` + `INTEGRATION.md` para um fork do Caelestia.

### Limite de verificação

Não há Caelestia instalado/rodando (apenas clone-fonte). A validação é **estática**: conformidade de símbolos contra o clone (`Colours.*`, `Tokens.*`, `Paths.*`, `Hypr.*`, componentes), `qmllint` quando possível e revisão independente. **Smoke test visual é obrigatório** pelo usuário depois de instalar o Caelestia.
