# PORT-SPEC — WhatsApp (caelestia-extras)

Fonte: `~/serpantinum/src/quickshell/whatsapp/WhatsAppPopup.qml` (299 l.), `bar/modules/WhatsAppWidget.qml` (166 l.), `reusables/LoaderIcon.qml` (spinner). AGPL-3.0.
Alvo: Caelestia `main` @ `d8ee1e8` (`/tmp/opencode/caelestia-ref`) + shims `src/extras/compat/`. API: `docs/CAELESTIA-API.md`.

## Bloqueadores identificados no recon (todos endereçados)

1. **`qs` resolve para o binário stock** (sem patch WebView). O wrapper `~/.local/bin/qs` é entregue por [W2]; a troca garante PATH/instalação.
2. **Pragma ausente**: `shell.qml` do Caelestia precisa de `//@ pragma EnableQtWebEngineQuick` (o launch só lê isso do arquivo de config). Entra no `install.sh` (orquestrador).
3. **`compat/ThemeBackend` incompleto**: faltam `overlay1`, `overlay2`, `subtext1` — corrigido pelo orquestrador antes das lanes.
4. **Re-host da janela**: não existe host de widgets do Serpantinum. Novo `WhatsAppOverlay.qml` com `StyledWindow` próprio.
5. **`LoaderIcon`** (import `"../"`): trocar por `LoadingIndicator`/`CircularIndicator` nativos.
6. **Patch não versionado**: [W2] extrai `.patch` + build script.
7. **Lazy load**: a WebEngine só deve inicializar na primeira abertura (RAM).

## Layout e donos

```
src/extras/whatsapp/
  WhatsAppOverlay.qml  # [W1] host: StyledWindow, 940x500 top-center, lazy Loader, abre/fecha
  WhatsAppPanel.qml    # [W1] port 1:1 do WhatsAppPopup.qml (WebEngine perfil/view, tema JS, timers)
  qmldir               # [W1] module qs.extras.whatsapp
patches/quickshell-webview.patch      # [W2]
scripts/build-quickshell-webview.sh   # [W2]
scripts/qs                            # [W2] wrapper p/ `qs` (prefixo patchado, fallback stock)
docs/QUICKSHELL-WEBVIEW.md            # [W2]
```

## API congelada (para o orquestrador integrar no `Extras.qml`)

```qml
// WhatsAppOverlay.qml
property bool visible: false
function toggle(): void
function show(): void
function hide(): void
```
Integração: `IpcHandler target "extras"` ganha `toggleWhatsApp()`; `CustomShortcut { name: "whatsapp" }`.

## Regras de adaptação (W1)

- **Perfil:** manter `storageName: "serpantinum-whatsapp-v2"` (preserva a sessão logada em `~/.local/share/quickshell/QtWebEngine/`), `offTheRecord:false`, cookies persistentes, UA Chrome/131.
- **Panel (port 1:1):** `WebEngineView` (`https://web.whatsapp.com`), injeção de tema via `waThemeVars`/`runJavaScript` usando `ThemeBackend.*`, `onLoadingChanged` com retry de tema (3 s), `onNewWindowRequested` → `xdg-open`, `onPermissionRequested` concedendo **apenas** `MediaAudioCapture` de origem contendo `whatsapp` e negando o resto, `onRenderProcessTerminated` recarrega em 800 ms, `Ctrl+R` recarrega.
- **RAM:** manter `memResetTimer` (1 h, com `resetPending` e reload ao esconder) e `renderCrashTimer`; nada de pré-carregar — `Loader { active: root._everOpened }`.
- **Overlay:** `Variants { model: Screens.screens; StyledWindow { required property ShellScreen modelData; screen: modelData; name: "extras-whatsapp"; WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusionMode: ExclusionMode.Ignore; WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand; anchors full } }`. Painel 940×500 centralizado no topo (margin-top ~52, escalado por `Scaler.s`); backdrop transparente fecha ao clique; `Esc` fecha; só a tela com foco (`Hypr.focusedMonitor.name === screen.name`) interage (padrão já usado no QuickActions).
- **Sem** `qs_manager.sh`, `SERPANTINUM_DIR`, `QS_RUN_DIR`, `FileView` de `current_widget`.
- **Abertura:** expor `toggle()/show()/hide()`; o orquestrador liga IPC/atalho.
- Cabeçalho `// Portado de Serpantinum: <caminho> (AGPL-3.0)`.

## Regras (W2)

1. Extrair o diff REAL do build patchado: repo `~/.local/src/quickshell-webview` (branch `wv-rebased`, base `2d3b3e9c70ef380dff751b61d334dc88df016c29` = `origin/master`), incluindo o untracked `build.sh` → `patches/quickshell-webview.patch` (formato `git diff`/`git apply`).
2. Validar: clonar quickshell em `/tmp` no rev base e rodar `git apply --check`; se o índice local estiver inconsistente (entradas `UU`), gerar o diff a partir do **working tree** (`git diff <base> -- src/`, e `diff -u` p/ untracked).
3. `scripts/build-quickshell-webview.sh`: build do prefixo `~/.local/opt/quickshell-webview` (RelWithDebInfo, `USE_JEMALLOC=OFF`, `BUILD_TESTING=OFF`, `CRASH_REPORTER=OFF`, `INSTALL_QML_PREFIX=lib/qt6/qml`), aplicando o patch num clone limpo; idempotente.
4. `scripts/qs`: wrapper que resolve o binário patchado (`~/.local/opt/quickshell-webview/bin/quickshell`, com `QML2_IMPORT_PATH`/`QML_IMPORT_PATH`) e cai para `/usr/bin/qs` se ausente.
5. `docs/QUICKSHELL-WEBVIEW.md`: por que existe, o que o patch faz (init dinâmica da QtWebEngineQuick via `QLibrary` lendo o pragma), como buildar, e que o rev bate com o master exigido pelo Caelestia.
6. Cabeçalho/atribuição no patch/docs; não versionar binários.

## Verificação (W1/W2)

1. `bash -n` no build script/wrapper; `git apply --check` do patch contra o rev base.
2. Nenhum `import "../"`, nenhuma env do Serpantinum, nenhum `qs_manager.sh`.
3. Símbolos de shim/core conferidos; `LoaderIcon` não usado.
4. Estático apenas; smoke test (login do WhatsApp e RAM) é do usuário.
