# PORT-SPEC — WhatsApp v2 (drawer nativo, minimalista) 

Decisões do usuário: **nativo igual à dock**; **minimalismo completo (single-chat, com toggle)**; **hover ao lado da barra (dwell)**; **página no Nexus**. Base: `docs/PLAN-WHATSAPP-CAELESTIA.md` + recons exp-10/11 + lib-3.

## Contrato congelado

```
src/extras/whatsapp/
  WhatsAppDrawer.qml   # [L1] painel nativo (full-height à esquerda): offsetScale/visible/open/close/scheduleHide; hospeda o Panel; SEM fundo próprio
  WhatsAppPanel.qml    # [L1] evoluir: tema WDS + minimal CSS, WebEngineScript+MutationObserver, alpha correto, sem frame opaco
  wa-theme.js          # [L1] snippet injetado (style qs-wa + observer + self-test)
  WhatsAppState.qml    # [L1] singleton: signal showRequested()/hideRequested(); property bool visible
  qmldir               # [L1] + Drawer
src/extras/settings/
  WhatsAppPage.qml           # [L3] conteúdo dos Ajustes
  WhatsAppSettingsWindow.qml # [L4] fallback standalone
scripts/
  patch-caelestia-whatsapp.py  # [L2] core: Panels/ContentWindow/Regions/Interactions
  patch-caelestia-nexus.py     # [L4] estender p/ a página WhatsApp
```

### API do Drawer (usada pelo patch do core)
- `required property ShellScreen screen`; `property var screenState`.
- `readonly property bool visible: offsetScale < 1`; `property real offsetScale` (0 visível → 1 oculto, `Behavior { Anim.DefaultSpatial }`).
- `anchors.top/bottom/left`; `anchors.leftMargin: (-implicitWidth - 5) * offsetScale`; `opacity: 1 - offsetScale`.
- `function open()/close()/scheduleHide()`; largura ~`Tokens.sizes.utilities.width` (ou `min(560, screen.width*0.42)`), full-height; **sem fundo próprio** (blob do core atrás); `Loader.active: visible || offsetScale < 1` (lazy; perfil preservado).
- Listens `WhatsAppState.showRequested/hideRequested` e só age se `Hypr.focusedMonitor.name === screen.name`.
- `Shortcut Escape { enabled: visible; onActivated: close() }`.

### Config (`extras.json → whatsapp`)
`openOnHover:true, hoverDwell:450, hideDelay:300, minimalMode:"full", hideSidebar:true, hideTabs:true, blur:true, transparency:85, unloadOnClose:false, fullscreenHide:true, sidebarShortcut:"Ctrl+B"`.

### Patch do core (L2) — pontos exatos (espelhar a sidebar/dock)
1. `Panels.qml`: `import qs.extras.whatsapp as ExtrasWhatsApp`; `readonly property alias whatsapp: whatsapp`; instância `ExtrasWhatsApp.Drawer { id: whatsapp; screen: root.screen; screenState: root.screenState; anchors.top: parent.top; anchors.bottom: parent.bottom; anchors.left: parent.left }`.
2. `ContentWindow.qml`: `PanelBg { id: whatsappBg; panel: panels.whatsapp; deformAmount: 0.03; implicitHeight: panel.height*(1/rawDeformMatrix.m22)+2 }` + `panels.whatsapp.transform: Matrix4x4 { matrix: whatsappBg.deformMatrix }`; em `keyboardFocus` (linha ~71) incluir `|| panels.whatsapp.visible` (OnDemand só quando visível).
3. `Regions.qml`: `R { panel: root.panels.whatsapp; y: 0; height: panel.height*(1-panel.offsetScale)+root.borderThickness }`.
4. `Interactions.qml` (sensor + dwell — faixa À DIREITA da barra):
```qml
readonly property real waEdgeW: Math.max(4, Tokens.padding.small)
property bool waEdgeHovered: false
Timer { id: waDwell; interval: 450; repeat: false; onTriggered: if (root.waEdgeHovered) root.panels.whatsapp.open() }
Timer { id: waHide; interval: 300; repeat: false; onTriggered: if (!root.inLeftPanel(root.panels.whatsapp, root.lastX, root.lastY) && !root.waEdgeHovered) root.panels.whatsapp.close() }
// em onPositionChanged (após o early-return de popouts.isDetached):
const onEdge = x >= bar.implicitWidth - 2 && x <= bar.implicitWidth + waEdgeW;
const inWa = inLeftPanel(panels.whatsapp, x, y);
waEdgeHovered = onEdge && !pressed && !popouts.hasCurrent;
if (waEdgeHovered) waDwell.restart(); else waDwell.stop();
if (inWa || onEdge) waHide.stop(); else if (panels.whatsapp.visible) waHide.restart();
// em onContainsMouseChanged: waHide.stop(); waDwell.stop(); panels.whatsapp.close()
```
   Suprimir o sensor quando `popouts.hasCurrent || pressed`; respeitar `fullscreenHide` (fechar em `onHasFullscreenChanged`).
5. `Exclusions.qml`: nada (mantém Ignore).

## Regras de design (L1/L3)

- **Painel (L1)**: remover o `Rectangle` de fundo próprio; o blob do core aparece atrás; manter a máscara de arredondamento do webview (`MultiEffect`); header/rótulos nativos (Tokens/Colours). Tema via **`--WDS-*`** (mapa de lib-3) com legado como fallback; corrigir alpha (`#RRGGBBAA`/`rgba()`); injeção com `<style id="qs-wa">` + `MutationObserver` (WebEngineScript DocumentReady); self-test de `#pane-side`/`[data-testid]`.
- **Minimalismo completo**: `hideTabs` (Communities/Updates/Channels), banners (`[data-testid=banner-*]`, `div[role=banner]`), `[data-testid=typing]`, badges; header enxuto; `hideSidebar` → `body.qs-hide-side #side { display:none }` com toggle (atalho `sidebarShortcut` + botão no painel); blur (`backdrop-filter`) quando `blur`.
- **Página (L3)**: `PageBase` "WhatsApp"; seções: Comportamento (abrir por hover + dwell, atraso p/ fechar, ocultar em fullscreen), Minimalismo (modo completo/moderado/cores, esconder abas, esconder sidebar + atalho), Aparência (blur, transparência, descarregar ao fechar). Persistência via `Extras.Config` (seção `whatsapp`).
- Cabeçalhos AGPL; não inventar símbolos.

## Verificação
Patches idempotentes (2ª execução no-op) em cópia; `qmllint` Qt6; sync + restart; screenshots (hover abre, painel fundido, tema) + observer; página no Nexus e fallback; sessão do WhatsApp preservada.
