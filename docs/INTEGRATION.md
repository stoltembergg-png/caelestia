# Integração no shell Caelestia — Fase 3

Este documento cobre a ligação do módulo QML nativo do `caelestia-whatsapp` ao
core do Caelestia. **O daemon não é tocado** por nada descrito aqui: esta fase
é apenas shell (QML) e o patch dos drawers.

- Instalador: [`../scripts/install-shell.sh`](../scripts/install-shell.sh)
- Patch do core: [`../patches/patch-caelestia-whatsapp.py`](../patches/patch-caelestia-whatsapp.py)
- Módulo QML: `shell/` deste repositório (a "lane shell", copiada para o core)
- Contrato de design de referência: `caelestia-extras/docs/PORT-SPEC-WHATSAPP-V2.md`

## 1. Visão geral

O Caelestia instalado vive em `$CAELESTIA_DIR` (default
`~/.config/quickshell/caelestia`). A Fase 3 faz duas coisas, ambas idempotentes
e sem `sudo`:

1. **Copia** o diretório `shell/` do repositório para
   `$CAELESTIA_DIR/extras/whatsapp/`.
2. **Patcheia** quatro ficheiros do core para instanciar e animar o `Drawer`
   do WhatsApp (`Panels.qml`, `ContentWindow.qml`, `Regions.qml`,
   `Interactions.qml`).

O módulo é importado pelo core como `qs.extras.whatsapp` (namespaced), tal como
a dock usa `qs.extras.dock`. O `extras/` do core já é uma raiz de import do
Quickshell; o subdiretório `whatsapp/` traz o seu próprio `qmldir`.

```
$CAELESTIA_DIR/
├── extras/
│   └── whatsapp/            # <- copiado de shell/ por install-shell.sh
│       ├── qmldir           #    module qs.extras.whatsapp
│       ├── WhatsAppState.qml      (singleton)
│       ├── Drawer.qml             (tipo `Drawer`; contrato abaixo)
│       └── ... (modules/components/services do painel)
└── modules/drawers/         # <- patcheado por patch-caelestia-whatsapp.py
    ├── Panels.qml
    ├── ContentWindow.qml
    ├── Regions.qml
    └── Interactions.qml
```

> O `qmldir` do módulo **tem** de declarar `module qs.extras.whatsapp`, os
> singletons (nomeadamente `WhatsAppState`) e o tipo `Drawer`. O instalador
> valida a presença de `qmldir` e avisa se o cabeçalho `module` não casar.

## 2. O que é patcheado no core

Todos os blocos são envolvidos por marcadores e aplicados de forma idempotente
(uma segunda execução é no-op). Cada ficheiro alterado ganha um backup
`.bak-<timestamp>` ao lado do original.

| Ficheiro | Alteração |
|---|---|
| `modules/drawers/Panels.qml` | `import qs.extras.whatsapp as ExtrasWhatsApp` (marcador); `readonly property alias whatsapp: whatsapp`; instância `ExtrasWhatsApp.Drawer { id: whatsapp; screen: root.screen; screenState: root.screenState; anchors.top/bottom/left: parent.* }` antes do `Sidebar.Wrapper`. |
| `modules/drawers/ContentWindow.qml` | `PanelBg { id: whatsappBg; panel: panels.whatsapp; deformAmount: 0.03; implicitHeight: panel.height * (1 / rawDeformMatrix.m22) + 2 }` junto aos demais; `whatsapp.transform: Matrix4x4 { matrix: whatsappBg.deformMatrix }` **dentro** do bloco `Panels`; `\|\| panels.whatsapp.visible` no binding de `WlrLayershell.keyboardFocus`. |
| `modules/drawers/Regions.qml` | `R { panel: root.panels.whatsapp; y: 0; height: panel.height * (1 - panel.offsetScale) + root.borderThickness }` (região de input full-height). |
| `modules/drawers/Interactions.qml` | Sensor de borda à **direita da barra** + dwell de 450 ms para abrir e timer de 300 ms para fechar; supressão quando `popouts.hasCurrent \|\| pressed \|\| fullscreen`; fecha ao perder o rato (`onContainsMouseChanged`) e em `onFullscreenChanged`. |

Marcadores usados (constantes `MARK_BEGIN`/`MARK_END` do patch):

```
// >>> caelestia-extras whatsapp
...
// <<< caelestia-extras whatsapp
```

### Rodar o patch isoladamente

```sh
# default: ~/.config/quickshell/caelestia
python3 patches/patch-caelestia-whatsapp.py

# diretório explícito
python3 patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR"

# ver o que faria, sem tocar em nada
python3 patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR" --dry-run
```

O patch valida as âncoras antes de editar: se um ficheiro ou uma âncora não
existir, imprime `AVISO:`/`ERRO:` com o caminho exato e não escreve lixo. Se
algum dos quatro ficheiros do core faltar, sai com código 2.

## 3. Como funciona o Drawer (contrato)

O tipo `Drawer` (em `shell/`, instalado como `qs.extras.whatsapp.Drawer`) é um
painel full-height ancorado à esquerda da área dos drawers, **sem fundo
próprio** — o blob/aro é desenhado pelo core (via `whatsappBg`).

- `property real offsetScale` — `0` = visível, `1` = oculto, com
  `Behavior { Anim.DefaultSpatial }`.
- `readonly property bool visible: offsetScale < 1`.
- `anchors.top/bottom/left`; `anchors.leftMargin: (-implicitWidth - 5) * offsetScale`;
  `opacity: 1 - offsetScale`.
- Funções `open()`, `close()`, `scheduleHide()`.
- `required property ShellScreen screen` e `property var screenState`.
- `Loader.active: visible || offsetScale < 1` (carregamento lazy; o conteúdo
  pesado só é instanciado quando necessário).
- `Shortcut Escape { enabled: visible; onActivated: close() }`.

### Sensor lateral + `WhatsAppState`

O patch de `Interactions.qml` define a faixa sensível à **direita da barra**:

```
x ∈ [bar.implicitWidth - 2, bar.implicitWidth + waEdgeW]
```

Quando o rato entra na faixa (`waEdgeHovered`), um timer de dwell de 450 ms
abre o painel; ao sair, um timer de 300 ms fecha-o. O sensor é suprimido se
`popouts.hasCurrent`, `pressed` ou `fullscreen`.

O singleton `WhatsAppState` permite desacoplar o pedido de abrir/fechar de
outros pontos da UI (barra, atalhos, IPC):

- `signal showRequested()` / `signal hideRequested()`
- `property bool visible`

O `Drawer` escuta esses sinais e só age se o monitor focado for o seu
(`Hypr.focusedMonitor.name === screen.name`).

## 4. Instalar

```sh
# a partir da raiz do repositório caelestia-whatsapp
bash scripts/install-shell.sh                          # core default
bash scripts/install-shell.sh /caminho/para/caelestia  # core explícito
bash scripts/install-shell.sh --dry-run                # ensaio, não altera
```

Passos que o script executa:

1. valida `shell/`, o `qmldir`, o patch e o `CAELESTIA_DIR`;
2. copia `shell/` → `$CAELESTIA_DIR/extras/whatsapp/`;
3. corre `python3 patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR"`;
4. imprime os próximos passos.

Reiniciar o shell para carregar o módulo:

```sh
caelestia shell -k && caelestia shell -d
```

Abrir/fechar: hover à direita da barra (dwell), o atalho global
`caelestia:whatsapp` (se existir na config Hyprland), ou via IPC. O estado do
daemon vê-se com `cwctl status` (o pareamento é `cwctl login`).

## 5. Desinstalar

1. **Reverter o core** — restaurar os backups criados pelo patch (os mais
   recentes, por timestamp):

   ```sh
   cd "$CAELESTIA_DIR/modules/drawers"
   ls -1t Panels.qml.bak-* ContentWindow.qml.bak-* Regions.qml.bak-* Interactions.qml.bak-*
   # confirme os timestamps e restaure:
   cp -a Panels.qml.bak-<ts> Panels.qml
   cp -a ContentWindow.qml.bak-<ts> ContentWindow.qml
   cp -a Regions.qml.bak-<ts> Regions.qml
   cp -a Interactions.qml.bak-<ts> Interactions.qml
   ```

   Em alternativa (o patch é idempotente e reversível por conteúdo), remova
   manualmente os blocos entre `// >>> caelestia-extras whatsapp` e
   `// <<< caelestia-extras whatsapp`. **Não** remova os marcadores da dock.

2. **Remover o módulo QML**:

   ```sh
   rm -rf "$CAELESTIA_DIR/extras/whatsapp"
   ```

3. Opcional: apagar os `.bak-*` antigos. O daemon continua a funcionar
   normalmente (não é afetado).

## 6. Migração futura para o plugin oficial (PR #1703)

O Caelestia `main` ainda **não** tem plugin system ativo; o PR **#1703**
(branch `feat/plugins`) define `manifest.json` + `entryPoints`
(`bar-entry`, `bar-popout`, `status-icon`, `quick-toggle`, `dashboard-tab`) e
passa a procurar plugins em `~/.local/share/caelestia/plugins`.

Quando esse system estabilizar, a migração **não toca no daemon nem no
protocolo IPC** (o `cwctl`/UDS mantêm-se):

1. empacotar `shell/services/WhatsApp.qml` + `shell/modules/whatsapp/` como um
   plugin (`manifest.json` com `entryPoints` `bar-entry`/`bar-popout`);
2. deixar de copiar para `extras/whatsapp/` e de patchear
   `Panels/ContentWindow/Regions/Interactions` — o plugin passa a ser
   descoberto em `~/.local/share/caelestia/plugins`;
3. manter o singleton/estado (`WhatsAppState`) e a API do `Drawer`
   (`offsetScale`/`open`/`close`) para não partir ligações internas.

Até lá, a via suportada é esta Fase 3 (copy + patch idempotente).
