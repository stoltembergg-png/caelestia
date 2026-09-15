# Caelestia API — referência para os módulos extras

Fonte: `/tmp/opencode/caelestia-ref` @ `d8ee1e8` (2026-09-11). **Não existem `qmldir` no core** — `import qs.<dir>` resolve relativo à raiz do shell (onde está `shell.qml`); o C++ só cobre `Caelestia.Config`.

## Imports
- `import Quickshell` → `Quickshell`, `Variants`, `Screens`, `Region`, `PersistentProperties`, `GlobalShortcut` não.
- `import Quickshell.Io` → `FileView`, `IpcHandler`, `Process`.
- `import Quickshell.Wayland` → `WlrLayershell`, `Region`.
- `import Quickshell.Hyprland` → `GlobalShortcut`, `Hyprland`.
- `import Caelestia.Config` → `Tokens`, `Config`, `GlobalConfig`.
- `import qs.services` → `Colours`, `Hypr`, `ShellState`, `Screens`, `Audio`, …
- `import qs.utils` → `Paths`, `Icons`, `SysInfo`.
- `import qs.components` / `.controls` / `.containers` / `.widgets` / `.misc` / `.effects` / `.images`.

## Tema
```qml
// services/Colours.qml (import qs.services)
Colours.palette.m3onSurfaceVariant   // conteúdo/texto/estado (cru)
Colours.tPalette.m3surfaceContainer  // superfícies (com transparência)
Colours.layer(Colours.palette.m3surfaceContainerHighest, 2)
Colours.on(colour)                   // cor de contraste
```
Tokens m3 disponíveis (nomes reais): `m3background, m3onBackground, m3surface, m3surfaceDim, m3surfaceBright, m3surfaceContainerLowest|Low|(default)|High|Highest, m3onSurface, m3surfaceVariant, m3onSurfaceVariant, m3inverseSurface, m3inverseOnSurface, m3outline, m3outlineVariant, m3shadow, m3scrim, m3surfaceTint, m3primary, m3onPrimary, m3primaryContainer, m3onPrimaryContainer, m3inversePrimary, m3secondary, m3onSecondary, m3secondaryContainer, m3onSecondaryContainer, m3tertiary, m3onTertiary, m3tertiaryContainer, m3onTertiaryContainer, m3error, m3onError, m3errorContainer, m3onErrorContainer, m3success, m3onSuccess, m3successContainer, m3onSuccessContainer, term0..term15`.

```qml
// plugin/src/Caelestia/Config/tokensattached.hpp  (import Caelestia.Config)
Tokens.rounding.{extraSmall,small,medium,large,largeIncreased,extraLarge,extraLargeIncreased,extraExtraLarge,full}
Tokens.spacing.{...}   // mesmos nomes
Tokens.padding.{...}   // mesmos nomes
Tokens.font.{headline,title,body,label,mono,icon}.{large,medium,small}  // {family,size,weight,italic,vaxes}
Tokens.font.clock, Tokens.font.workspaces
Tokens.anim.{standardDecel,...}; Tokens.anim.durations.{small 200, normal 400, large 600, extraLarge 1000, expressiveFastSpatial 350, expressiveDefaultSpatial 500, expressiveSlowSpatial 650, expressiveFastEffects 150, expressiveDefaultEffects 200, expressiveSlowEffects 300}
Tokens.sizes.{bar,dashboard,launcher,notifs,osd,session,sidebar,utilities,lock,winfo,nexus}
Tokens.transparency.{enabled,base,layers}
```

## Paths / persistência
```qml
// utils/Paths.qml (import qs.utils)
Paths.home, .pictures, .videos, .data, .state, .cache, .config, .imagecache, .wallsdir, .recsdir, .libdir
Paths.toLocalFile(path), .absolutePath(path), .shortenHome(path)

// FileView (import Quickshell.Io)
FileView { path: `${Paths.state}/scheme.json`; watchChanges: true; onFileChanged: reload(); onLoaded: root.load(text(), false) }

// PersistentProperties (import Quickshell)
PersistentProperties { id: props; property bool running: false; reloadableId: "recorder" }
```

## Telas / estado por tela
```qml
Screens.screens                       // list<ShellScreen> (só habilitadas)
ShellState.forScreen(screen) -> ScreenState
ShellState.forActive() -> ScreenState
ShellState.componentsFor(screen) -> Components   // slots: background, rootWindow, interactionWrapper, bar, panels
ComponentRef { screen; slot; component }         // referencia um item no slot
```
`ScreenState` (components/ScreenState.qml) tem bools: `bar, osd, session, launcher, dashboard, utilities, sidebar` + `dashboardTab`.

## Hypr
```qml
// services/Hypr.qml (import qs.services)
Hypr.toplevels, Hypr.workspaces, Hypr.monitors           // ObjectModel (.values/.find)
Hypr.activeToplevel, Hypr.focusedWorkspace, Hypr.focusedMonitor, Hypr.activeWsId
Hypr.dispatch(request: string)
Hypr.monitorFor(screen), Hypr.toplevelsForWs(ws), Hypr.isToplevelIgnored(tl)
// toplevel: .title .class .address .workspace.id .lastIpcObject.{class,fullscreen,mapped,windows,specialWorkspace.name}
```

## Overlay por tela (padrão do core — AreaPicker.qml:18-47)
```qml
Variants {
    model: Screens.screens
    StyledWindow {              // components/containers/StyledWindow.qml (PanelWindow + namespace "caelestia-<name>")
        required property ShellScreen modelData
        screen: modelData
        name: "extras-quickactions"
        WlrLayershell.exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        anchors.top: true; anchors.bottom: true; anchors.left: true; anchors.right: true
        mask: <Region ou null>
    }
}
```
Valores: `ExclusionMode.{Ignore,Normal,Exclusive}`, `WlrLayer.{Background,Bottom,Top,Overlay}`, `WlrKeyboardFocus.{None,OnDemand,Exclusive}`.

## IPC + atalho
```qml
IpcHandler {
    function toggle(): void { ... }
    target: "extras"           // chamado por: qs -c caelestia ipc call extras toggle
}
CustomShortcut { name: "extras"; description: "..."; onReleased: ... }  // GlobalShortcut appid "caelestia"
```
Bind Hyprland (Lua): `hl.dsp.global("caelestia:extras")`.

**Targets IPC ocupados (não reutilizar):** `drawers, nexus, toaster, picker, hypr, audio, brightness, gameMode, idleInhibitor, notifs, mpris, wallpaper, lock`.
**GlobalShortcut ocupados:** `nexus, showall, dashboard, session, launcher, launcherInterrupt, sidebar, utilities, screenshot, screenshotFreeze, screenshotClip, screenshotFreezeClip, refreshDevices, brightnessUp/Down, mediaToggle/Prev/Next/Stop, clearNotifs, lock, unlock`.

## Componentes nativos reais
- controls: `ButtonBase`, `IconButton`, `TextButton`, `IconTextButton`, `StyledTextField`, `Menu`+`MenuItem`, `StyledSlider`, `FilledSlider`, `StyledSwitch`, `StyledProgressBar`, `CircularProgress`, `CircularIndicator`, `LoadingIndicator`, `SplitButton`, `SearchBar`, `StyledScrollBar`, `StyledRadioButton`, `StyledSpinBox`, `CustomMouseArea`.
- containers: `StyledWindow`, `StyledListView`, `StyledFlickable`, `VerticalFadeListView`, `VerticalFadeFlickable`.
- base: `StateLayer` (MouseArea), `StyledRect`, `StyledText`.
- effects: `ColouredIcon`, `Colouriser`, `Elevation`, `Mask`.
- images: `CachingImage`, `CachingIconImage`, `FadeImage`.

## Registro de módulo extra (sem C++)
1. Pasta `extras/` na raiz do config (ao lado de `shell.qml`).
2. Em `shell.qml`: `Loader { source: "extras/Extras.qml"; asynchronous: true }` (ou `import "extras"`).
3. De qualquer arquivo: `import qs.extras`.
4. `extras/qmldir` próprio para singletons (`singleton Nome 1.0 caminho.qml`).
5. **Subpastas importadas por URI (`qs.extras.<sub>`) precisam de `qmldir` próprio** (`module qs.extras.<sub>` + entradas) — o scanner do Quickshell não segue `Loader.source`, e sem qmldir o import falha. Singletons ficam no `extras/qmldir` da raiz. Confirmado no review ora-1.
