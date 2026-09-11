# PORT-SPEC — No Limits / KodexBar (caelestia-extras)

Fonte: `~/serpantinum/src/quickshell/{singletons/NoLimits.qml,kodexbar/KodexBarPopup.qml,kodexbar/qmldir,bar/modules/KodexBarWidget.qml}` + `~/serpantinum/src/scripts/ai-memory-probe.sh` (AGPL-3.0).
Alvo: Caelestia `main` @ `d8ee1e8` (`/tmp/opencode/caelestia-ref`) + shims de `src/extras/compat/`. API: `docs/CAELESTIA-API.md`.

## Layout e donos (escopos disjuntos)

```
src/extras/nolimits/
  NoLimits.qml        # [N1] singleton (motor de quota, ai-memory, eventos, notificações)
  NoLimitsPopup.qml   # [N2] UI 4 abas (Limits/Memory/Activity/Settings)
  NoLimitsOverlay.qml # [N2] host StyledWindow (popup próprio, zero patch de core)
  NoLimitsBarItem.qml # [N2] cápsula compacta p/ a barra (usada pelo patch opcional do core)
  qmldir              # [N2] module qs.extras.nolimits + 3 entradas
src/extras/scripts/ai-memory-probe.sh   # [N1]
src/extras/assets/languages/{en,pt}.json # [N2] chaves kodexbar.*
```
Fora do escopo dos fixers (integração é do orquestrador): `src/extras/qmldir` (raiz), `Extras.qml`, `install.sh`, docs, patch do core, migração.

## API pública congelada (N1 fornece; N2 consome)

Manter a API do original (providers, cards, displayMode, disabledList, thresholds, notify, notifyCooldown, requestedView, memory/sessions/cost, `severityFor`, `fmtReset`, …) e **adicionar**:
```qml
property bool visible: false
function show(view: string): void      // view ∈ {"limits","memory","activity","settings"}
function hide(): void
function toggle(): void
signal showRequested(string view)      // overlay escuta; também usado pela ação da notificação
```
Config: usar `Config.getSetting("noLimits", { defaults inline })` (NÃO editar `compat/Config.qml`). Estado: `Caching.getStateDir("nolimits")` (já aponta p/ `~/.local/state/caelestia/nolimits`).
Externo (host, inalterado): `kodexbar-quotas`, `ai-memory`, `~/.local/share/opencode/opencode.db`, `curl`, `jq`.

## Adaptações obrigatórias (N1)

1. Imports: `import qs.extras` (shims), `qs.services` quando necessário; remover singletons do Serpantinum.
2. `KodexBarPopup`/anchor/IPC: substituir `qs_manager.sh`/`send_qs_ipc` por sinais internos (`showRequested`); **nada** de IPC externo para abrir o overlay.
3. **Notificações (crítico):** NÃO criar outro `NotificationServer` (o core é dono do D-Bus, `services/Notifs.qml:84`). Enviar via `gdbus call org.freedesktop.Notifications.Notify …` dentro de um `Process` (parsear o id retornado) e tratar a ação "Abrir" com um `Process` persistente `gdbus monitor --session --dest org.freedesktop.Notifications` que escuta `ActionInvoked` e mapeia id→view→`show(view)`. Se `Notifs.dnd` existir em `qs.services`, suprimir popup quando ativo (manter o evento).
4. `barWindow`/`s()`: não existem no overlay; usar `Scaler.s()` (shim) e `Tokens.*` onde fizer sentido.
5. i18n: mesmas chaves `kodexbar.*` (N2 mescla en/pt do Serpantinum).
6. Cabeçalho `// Portado de Serpantinum: <caminho> (AGPL-3.0)` em cada arquivo.
7. Não inventar API: confirmar em `docs/CAELESTIA-API.md` / clone.

## UI (N2)

1. `NoLimitsOverlay.qml`: `Variants { model: Screens.screens; StyledWindow { required property ShellScreen modelData; screen: modelData; name: "extras-nolimits"; WlrLayershell.layer: WlrLayer.Overlay; WlrLayershell.exclusionMode: ExclusionMode.Ignore; WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand; anchors full } }`. Mostrar só quando `NoLimits.visible`; painel ~430×520 (`Tokens.sizes.utilities.width`?) ancorado perto da barra; backdrop transparente que fecha ao clique; `Esc` fecha. Escutar `NoLimits.showRequested`.
2. `NoLimitsPopup.qml`: port 1:1 do original (4 abas, cards, thresholds, cooldown, anim), trocando `Scaler`/`ThemeBackend`/`I18n`/`IconButton` pelos shims e removendo dependências de barra.
3. `NoLimitsBarItem.qml`: cápsula compacta (ícone + %/severidade + badge de handoffs + ponto offline), clique esq. → `NoLimits.toggle()`, clique dir. → cicla `displayMode`; visual nativo (`Colours`, `Tokens`, `StateLayer`), sem arquivo de âncora.
4. `qmldir`: `module qs.extras.nolimits` + `NoLimitsOverlay`, `NoLimitsPopup`, `NoLimitsBarItem`.
5. i18n: coletar TODAS as chaves `kodexbar.*` usadas nos fontes (`grep -rhoE 'I18n\.t\("kodexbar[^"]*"'`) e mesclar en/pt do Serpantinum (`assets/languages/{en,pt}.json`) no JSON do repo (merge via Python, sem perder chaves existentes).

## Patch opcional do core (orquestrador, depois)

- `modules/bar/Bar.qml`: `DelegateChoice { roleValue: "kodexbar"; NoLimitsBarItem {} }` (import `qs.extras.nolimits`), marcador para ser aplicado por `install.sh` com backup.
- `~/.config/caelestia/shell.json`: entrada `{ "id": "kodexbar", "enabled": true }` em `bar.entries` (idempotente).
- `Extras.qml`: instanciar `NoLimitsOverlay {}` + IPC `extras toggleNoLimits/setNoLimitsView` + `CustomShortcut { name: "nolimits" }`.
- Migração: copiar bloco `noLimits` de `~/.config/serpantinum/settings.json` p/ `extras.json` e `~/.local/state/serpantinum/nolimits/*` → `~/.local/state/caelestia/nolimits/` (uma vez).

## Verificação

1. `python3 -m py_compile` / `bash -n` nos scripts.
2. Nenhum `import "../"`, nenhuma env do Serpantinum, nenhum `NotificationServer`.
3. Símbolos de shim existentes; símbolos do core conferidos no clone.
4. Cabeçalhos AGPL; `qmldir` com entradas corretas.
5. Estático apenas (sem runtime do Caelestia); smoke test é do usuário.
