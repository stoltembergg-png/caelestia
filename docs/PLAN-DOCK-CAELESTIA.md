# PLANO — Dock do Serpantinum integrada ao Caelestia

Requisitos do usuário: **sempre visível no rodapé**, **conectada ao "aro"** do Caelestia, **animação suave** de hover nos ícones e **configurações nos Ajustes** (auto-ocultar, animações, transparência). Integração "perfeita", no nível do No Limits.

## Estado atual (evidências)

- **Dock existe e está instalada, mas invisível**: `Dock.qml:284` exige `dockAppsModel.count > 0 || editMode`; `apps: []` → `visible:false`. Também some em fullscreen (`Dock.qml:310-317`).
- **Config atual** (`~/.config/caelestia/extras.json → dock`): `{enabled:true, position:"bottom", elementSize:44, floating:false, editing:false, apps:[]}`. Chaves ausentes caem em defaults do código (`opacity=100`, `exclusive=false`, `autohide=false`, `autohideTimeout=1000`, `hoverScale=120`, `cascadeScale=false`, `enableScrolling=false`, `visibleElements=7`).
- **Visual próprio**: fundo `Rectangle` (`ThemeBackend.base`) + `Shape`s de canto (`Dock.qml:889-1183`); raio `ThemeBackend.borderRadius` (8). **Não usa** `Config.border.*` → não casa com o aro (espessura 10 / raio 25 / smoothing 20 / cor `tPalette.m3surface`).
- **Janelas**: `extras-dock-exclusion` (`ExclusionMode.Normal`, zona 36) + `extras-dock` (`Ignore`), por tela (`Variants`), camada `Top`.
- **Hover atual**: índice discreto + `Behavior` fixo **220 ms OutCubic** (`Dock.qml:1355-1362,1433-1435`); `cascadeScale` off; sem `Anim`/spring do core.
- **Aro do Caelestia**: desenhado no `ContentWindow` por `BlobGroup` + `BlobInvertedRect` (`:159-175`); painéis são `BlobRect` no **mesmo grupo** e o shader funde tudo (`sink`, `blob.frag:191-240`). O grupo **não é exportado**; existe uso autônomo de blobs (`modules/nexus/common/BlobPopup.qml:30-59`, `import Caelestia.Blobs`).
- **Rodapé**: `Interactions` dá hover ao **launcher no centro** (`:199-208`) e **utilities à direita** (`:229-238`) → conflitos se a dock for central/direita sem zona própria.
- **Nexus**: páginas em `PageRegistry.qml` + `PageCompRegistry.qml` (**mesmo índice**); controles prontos (`PageBase`, `SectionHeader`, `ToggleRow`, `SliderRow`…); persistência de página custom = `extras.json` via shim (`import qs.extras as Extras`); animações da dock hoje são **hardcoded**.

## Arquitetura proposta

```
extras/dock/          Dock.qml (existente; evoluir)  +  DockController? (opcional)
extras/settings/      DockPage.qml  (conteúdo dos Ajustes)
patches/              patch-caelestia-nexus.py (marcadores; 2 registries + DockPage)
scripts/              instalação idempotente (install.sh já orquestra)
```

### Fases

**F1 — Visibilidade e comportamento base (sem tocar no core)**
- Remover o gate de apps: `visible: initialized && dockEnabled && (alwaysVisible || apps>0 || editMode)`; novo toggle `alwaysVisible` (default **true**) e `showOnFullscreen` (default **true**, já que "sempre visível").
- `exclusive` default **true** para reservar o rodapé (`isEffectivelyExclusive` sem exigir apps).
- Defaults no shim `compat/Config.qml` para TODAS as chaves que a dock lê (`opacity, exclusive, autohide, autohideTimeout, hoverScale, cascadeScale, enableScrolling, visibleElements, alwaysVisible, showOnFullscreen, animations`).

**F2 — Conexão com o aro (decisão pendente A/B)**
- **B (nativo real)**: dock vira painel nativo — `Panels.qml` (Wrapper bottom) + `ContentWindow.qml` (PanelBg no `blobGroup`) + `Regions.qml` (máscara) + `Exclusions.qml` (zona inferior); patch idempotente com marcadores. Solda/sink verdadeiros.
- **A (zero-core)**: manter as janelas atuais e desenhar um `BlobGroup` próprio no `extras-dock` com `BlobInvertedRect` (aro inferior clonado com `Config.border.*`) + `BlobRect` da dock no mesmo grupo (funde no aro clonado). 95% de fidelidade; risco de z-order/aro duplicado.
- **A-suave**: manter o fundo atual e animar raio/altura/cor para "fluir" do aro sem duplicá-lo.

**F3 — Animação premium de hover**
- Trocar os `Behavior` por `Anim { type: Anim.FastSpatial/DefaultSpatial }` (Tokens) e/ou `SpringAnimation`; cursor rastreado no `dockContainer` (HoverHandler + `mapFromItem`) com escala por **distância contínua** (não por índice), ativando `cascadeScale` por padrão; toggle `animations` (liga/desliga) e `hoverScale`/raio de influência configuráveis.

**F4 — Ajustes no Nexus (decisão pendente)**
- `DockPage.qml` (em `extras/settings/`) com seções: **Comportamento** (sempre visível, auto-ocultar + timeout, fullscreen), **Aparência** (transparência, tamanho dos ícones, posição), **Animações** (on/off, intensidade do hover/cascata).
- **Híbrido recomendado**: página em `extras/` + patch do Nexus (marcadores) inserindo-a nos 2 registries no fim da categoria "shell" + fallback standalone (IPC `extras openDockSettings` / atalho `caelestia:docksettings`).
- Persistência: `Extras.Config.setSetting("dock", …)` (aplica ao vivo via `onRawSettingsChanged`).

**F5 — Validação**
- `install.sh` aplica patches idempotentes (Nexus/bar/dock-core conforme decisão) + sync; restart; screenshots; observer; smoke test do usuário (hover, auto-ocultar, transparência, settings).

## Riscos e cuidados

- **Upgrade do fork**: registries do Nexus já divergem do upstream e não têm marcadores → alto risco de perda; mitigar com marcadores + backup `.bak-*` + script de reaplicação.
- **Índices do Nexus**: `PageRegistry` e `PageCompRegistry` devem manter ordem/quantidade — inserir sempre no mesmo ponto, com validação de tamanho no script.
- **Conflito de rodapé** com launcher (centro) e utilities (direita): requer zona de exclusão própria e, se necessário, ajuste do `Interactions`.
- **Foco/teclado** (`focusable: editMode`) e picker: manter comportamento atual; sem fullscreen.
- **`Caching`↔`minimize.sh`**: mesmo diretório de estado (ok hoje) — não quebrar.

## Decisões pendentes (perguntar antes de implementar)

1. **Fidelidade visual**: B nativo real (patch core 4–5 arquivos) × A zero-core (aro clonado) × A-suave.
2. **Ajustes**: híbrido (página + patch no Nexus) × só standalone (zero patch).
3. **Fullscreen**: manter a dock visível (padrão) × ocultar automaticamente.
