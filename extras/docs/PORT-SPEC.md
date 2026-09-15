# PORT-SPEC — caelestia-extras (contrato congelado)

Alvo: Caelestia `main` @ `d8ee1e8` (`/tmp/opencode/caelestia-ref`), Quickshell git master.
Fonte: `~/serpantinum/src/quickshell` (AGPL-3.0). Instalar em `$CAELESTIA_DIR/extras` (default `~/.config/quickshell/caelestia/extras`).
Referência de API: `docs/CAELESTIA-API.md`.

## Layout congelado (o repo deve terminar exatamente assim)

```
src/extras/
  qmldir                      # [A]
  Extras.qml                  # [A] entry: QuickActions {} + Dock {} + IpcHandler "extras" + CustomShortcuts
  compat/                     # [A] singletons de adaptação
    ThemeBackend.qml Scaler.qml Config.qml Caching.qml I18n.qml
    Sounds.qml SysData.qml OsdController.qml FloatingController.qml NotesManager.qml
  reusables/                  # [A] só os usados
    qmldir IconButton.qml ClickButton.qml DeleteButton.qml Input.qml
  assets/languages/en.json pt.json   # [A] chaves quickactions.* e dock.* do Serpantinum
  quickactions/               # [B]
    qmldir QuickActions.qml Notepad.qml NotesList.qml DrawAction.qml
  dock/qmldir Dock.qml        # [C]
  scripts/notepad/md_render.py    # [B]
  scripts/minimize.sh             # [C]
```

> **Subpastas exigem `qmldir` próprio** (`module qs.extras.<sub>` + entradas): o scanner do Quickshell
> não segue `Loader.source`; sem qmldir, `import qs.extras.reusables`/relativos falham. O `extras/qmldir`
> da raiz cobre apenas os singletons. (Confirmado no review ora-1.)

`qmldir` (conteúdo exato):
```
singleton ThemeBackend 1.0 compat/ThemeBackend.qml
singleton Scaler 1.0 compat/Scaler.qml
singleton Config 1.0 compat/Config.qml
singleton Caching 1.0 compat/Caching.qml
singleton I18n 1.0 compat/I18n.qml
singleton Sounds 1.0 compat/Sounds.qml
singleton SysData 1.0 compat/SysData.qml
singleton OsdController 1.0 compat/OsdController.qml
singleton FloatingController 1.0 compat/FloatingController.qml
singleton NotesManager 1.0 compat/NotesManager.qml
Extras 1.0 Extras.qml
```

## Convenções de import (obrigatórias)

- Arquivos em `extras/**` usam **`import qs.extras`** para os singletons (não `import "../"`).
- `import qs.services` (`Colours`, `Hypr`, `ShellState`, `Screens`), `import qs.utils` (`Paths`),
  `import Caelestia.Config` (`Tokens`, `Config`/`GlobalConfig` do core **não** usar — colidiria com o shim),
  `import Quickshell`, `import Quickshell.Io`, `import Quickshell.Wayland`, `import Quickshell.Hyprland`,
  componentes: `qs.components`, `qs.components.controls|containers|widgets|misc|effects|images`.
- **Nunca** inventar símbolo: só usar o que existe em `docs/CAELESTIA-API.md` / no clone.

## Camada compat (lane A) — mapeamento

- `ThemeBackend`: expor **todos** os símbolos usados nos arquivos portados (`grep -rho "ThemeBackend\.[A-Za-z0-9_]*"`) mapeando p/ `Colours.palette.*` (conteúdo) ou `Colours.tPalette.*` (superfícies); cores sem token m3 → token m3 mais próximo. Radii/forem números → `Tokens.rounding.*`; `fontFamily` → `Tokens.font.body.medium.family`.
- `Scaler`: `baseScale` (real, default 1.0 lido de `Config`) + `s(v) = v * baseScale`.
- `Config`: lê/escreve `~/.config/caelestia/extras.json` via `FileView`; expõe `settingsLoaded`, `dataReady`, `rawSettings`, `getSetting(section, def)`, `setSetting(section, value)`; defaults p/ `dock`, `bar`, `general`, `display` conforme consumo dos componentes.
- `Caching`: `getStateDir(n)`→`Paths.state+"/"+n`; `getRunDir(n)`→`(Quickshell.env("XDG_RUNTIME_DIR")||Paths.state+"/run")+"/caelestia-extras-"+n`; `getLogDir(n)`→`Paths.state+"/logs/"+n`; `qsDir`→`Quickshell.shellDir`; `serpantinumDir`→`Quickshell.shellDir+"/extras"`; criar dirs com `mkdir -p` (`Process`/`execDetached`).
- `I18n`: `t(key, args)` de `assets/languages/{lang}.json` (lang de `GlobalConfig`/Config), com fallback legível (última parte da chave) se faltar; carregar via `FileView`.
- `Sounds`: `playSfx(name)` no-op.
- `SysData`: `prewarm()`/`subscribe()`/`unsubscribe()` no-op + propriedades usadas pelo host (`cpu, ramPercent, ramGb, temp, netRx, netTx, diskPercent, diskGb, diskTotalGb, isScanningNet, scanNetwork()`).
- `OsdController`: `isFullscreen` ← `Hypr.activeToplevel?.lastIpcObject?.fullscreen ?? false`.
- `FloatingController`: singleton com `property int activeIndex`, `function setIndex(i)`, `signal showRequested(string tab)`, `function show(tab)`; alvo do host.
- `reusables/*`: portar `IconButton`, `ClickButton`, `DeleteButton`, `Input` do Serpantinum trocando `ThemeBackend`→shim (ou reescrever sobre `qs.components.controls`), mantendo a API consumida.

## Host Quick Actions (lane B)

- Root: `Variants { model: Screens.screens; StyledWindow { required property ShellScreen modelData; screen: modelData; name: "extras-quickactions"; WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusionMode: ExclusionMode.Ignore; anchors full; mask: <região de bordas> } }`.
- Portar de `quickactions/Floating.qml`: mask/Regiões de borda, timers hover, morfologia, abas `Notepad`/`DrawAction` (largar `Timer`/`SystemUsage`/mini-dock), contrato injetado (`scaleFunc`, `mochaColors: ThemeBackend`, `activeEdge`, `panelChromeLength`, `isCurrentTarget`) e `preferredWidth/preferredExtraLength/requestedLayoutTemplate`.
- Estado/abertura por `FloatingController` (`activeIndex`, `show(tab)`); abrir também via hover de borda como no original.
- `Notepad`/`NotesList`/`DrawAction`: portar quase 1:1; trocar `import "../"`→`import qs.extras`; manter `NotesManager` (json em `Caching.getStateDir("notepad")`) e `md_render.py` (chamado via `Process`, caminho `Caching.serpantinumDir+"/scripts/notepad/md_render.py"`), com fallback Qt já existente.
- `DrawAction` = a lousa: manter canvas, ferramentas, undo/redo, zoom/pan, salvar em `Paths.pictures` e `wl-copy`.

## Dock (lane C)

- Portar `dock/Dock.qml` mantendo comportamento (autohide, magnify, reorder, picker, min-strip), trocando: `import "../"`→`import qs.extras`; root `Variants`+`StyledWindow` (name `extras-dock`); `Config.rawSettings.dock`→shim; `ThemeBackend`/`Scaler`/`Caching`/`Sounds`/`I18n`/`OsdController`→shims; `minimize.sh` portado para `Paths.state` (sem depender de env do Serpantinum) e dispatch de workspace virtual via `Hypr.dispatch`.
- Se necessário, quebrar em subcomponentes, mas manter a API de nível raiz.

## Extras.qml (lane A)

- `Item { QuickActions {}; Dock {} }` + `IpcHandler { target: "extras"; toggleQuickActions(); setQuickActionsTab(int); toggleDock() }` + `CustomShortcut { name: "quickactions" }` e `CustomShortcut { name: "dock" }` (delegando a `FloatingController`/`Config`). Sem colisão com a lista de nomes ocupados.

## Critérios de verificação (cada lane)

1. Todo símbolo de outro módulo usado existe (grep no shim/clone). Nada inventado.
2. `python3 -m py_compile` nos scripts Python; `bash -n` nos scripts shell.
3. Sem `import "../"` nem referência a singletons do Serpantinum fora dos shims.
4. Comentário de cabeçalho em cada arquivo portado citando a origem (`Serpantinum: <caminho>`, AGPL-3.0).
5. Diferenças deliberadas listadas no final (o que foi cortado/adaptado).

> Sem runtime do Caelestia, a validação é estática (conformidade + revisão). O smoke test visual é do usuário.
