# PORT-SPEC — Dock nativa no Caelestia (F1–F4)

Decisões do usuário: **nativo real conectado ao aro**; **página nos Ajustes (Nexus) + fallback standalone**; **ocultar em fullscreen**.
Base: `docs/PLAN-DOCK-CAELESTIA.md` + recons (exp-7/8/9). Core: `/tmp/opencode/caelestia-ref`; instalado: `~/.config/quickshell/caelestia`.

## Contrato congelado

```
src/extras/dock/
  DockPanel.qml      # [L1] conteúdo visual (ícones/hover/picker/min-strip), SEM janela/fundo próprio
  DockWrapper.qml    # [L1] painel nativo: Item com offsetScale/sensorHeight/reservedSpace; hospeda DockPanel
  DockState.qml      # [L1] singleton: property real reservedSpace (p/ Exclusions); visible/fullscreenState
  qmldir             # [L1] module qs.extras.dock: Wrapper->DockWrapper, DockPanel
src/extras/settings/
  DockPage.qml           # [L3] conteúdo dos Ajustes (Nexus)
  DockSettingsWindow.qml # [L4] fallback standalone (FloatingWindow com o mesmo conteúdo)
  qmldir                 # [L4] module qs.extras.settings
patches/  (scripts/)
  scripts/patch-caelestia-dock.py    # [L2] core: Panels/ContentWindow/Regions/Exclusions
  scripts/patch-caelestia-nexus.py   # [L4] core: PageRegistry/PageCompRegistry
```

### API do painel (usada pelo patch do core)
- `DockWrapper` (Item): `required property ShellScreen screen`; `property real offsetScale` (0=visível, 1=oculto; anima); `property real sensorHeight` (faixa de hover p/ autohide; default 6); `implicitWidth/implicitHeight`.
- `DockState` (singleton): `property real reservedSpace` (atualizado pelo wrapper: altura quando `exclusive && !autohide && visível`, senão 0); `property bool fullscreenActive` (para ocultar; o wrapper lê `Hypr.activeToplevel?.lastIpcObject?.fullscreen` ou equivalente).
- Config (extras.json → `dock`): existentes + `alwaysVisible` (default **true**), `showOnFullscreen` (default **false**), `animations` (true), `exclusive` (default **true**), `autohide` (false), `autohideTimeout` (1000), `opacity` (100), `elementSize` (44), `hoverScale` (120), `cascadeScale` (true), `sensorHeight` (6), `position` (fixo `"bottom"` por ora).

### Patch do core (L2) — pontos exatos (instalado; espelhar no ref)
1. `modules/drawers/Panels.qml`
   - `import qs.extras.dock as ExtrasDock` (no topo, marcador).
   - `readonly property alias dock: dock` (junto aos outros aliases, marcador).
   - `ExtrasDock.Wrapper { id: dock; screen: root.screen; screenState: root.screenState; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottom: parent.bottom }` (marcador).
2. `modules/drawers/ContentWindow.qml`
   - `PanelBg { id: dockBg; panel: panels.dock; deformAmount: 0.1 }` (marcador, junto aos demais).
   - `panels.dock.transform: Matrix4x4 { matrix: dockBg.deformMatrix }` (marcador, junto ao bloco de wiring).
3. `modules/drawers/Regions.qml`
   - `R { panel: root.panels.dock; y: root.win.height - height; height: Math.max(panel.height * (1 - panel.offsetScale), panel.sensorHeight) + root.borderThickness }` (marcador).
4. `modules/drawers/Exclusions.qml`
   - `import qs.extras as Extras` (alias! o core também tem `Config` atachado) e bloco:
     `StyledWindow { screen: root.screen; name: "border-exclusion"; anchors.bottom: true; exclusiveZone: Extras.DockState.reservedSpace; mask: Region {}; implicitWidth: 1; implicitHeight: 1 }` (marcador).
- Regras: marcadores `// >>> caelestia-extras dock` / `// <<< caelestia-extras dock`, backup `.bak-*`, `--dry-run`, idempotente, testar em CÓPIA (`/tmp/opencode/caelestia-docktest`).

### Patch do Nexus (L4)
- `modules/nexus/PageRegistry.qml` + `modules/nexus/PageCompRegistry.qml`: import `qs.extras.settings as ExtrasSettings` (marcador) e inserir `{ label: qsTr("Dock"), icon: "dock", description: qsTr("Comportamento, aparência e animações da dock"), category: "shell" }` + `Component { StackPage { Component { ExtrasSettings.DockPage {} } } }` — **no fim das duas listas** (evita deslocar índices); validar que as listas ficam do mesmo tamanho.
- `Extras.qml`: IPC `openDockSettings()` (abre `DockSettingsWindow`) + `CustomShortcut { name: "docksettings" }`.

## Regras de design (L1/L3)

- **L1**: sem janelas próprias (`StyledWindow`/exclusão saem); `DockPanel` = GridLayout/Repeater atuais + picker/min-strip; fundo transparente (o blob nativo aparece); cantos via `BlobRect` do core (nada próprio). Animação premium: `Anim`/`SpringAnimation` (Tokens), hover por **distância contínua** (HoverHandler no container + `mapFromItem`), `hoverScale`/`cascadeScale`; autohide com sensor de borda; fullscreen oculta (`showOnFullscreen=false`); `offsetScale` animado.
- **L3**: usar `PageBase`/`SectionHeader`/`ToggleRow`/`SliderRow`/`SelectRow`; `import qs.extras as Extras` e `Extras.Config.getSetting/setSetting("dock", …)`; seções: Comportamento (sempre visível, auto-ocultar + timeout, fullscreen), Aparência (transparência 0–100, tamanho), Animações (ligar, intensidade).
- Cabeçalhos AGPL; não inventar símbolos; conferir no core.

## Verificação
- `py_compile`/`bash -n`; patches idempotentes (2ª execução no-op) e `qmllint` (Qt6) na cópia; sync para a árvore viva; restart; screenshots + observer (blob conectado ao aro, hover suave, página nos Ajustes); fallback standalone via IPC.
