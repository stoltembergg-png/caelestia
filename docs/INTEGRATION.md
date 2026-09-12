# Integração no shell Caelestia — Fases 3 e 5

Este documento cobre a ligação do módulo QML nativo do `caelestia-whatsapp` ao
core do Caelestia: o **Drawer** (Fase 3), o **badge/entrada na barra** e a
**página "WhatsApp" nos Ajustes (Nexus)** (Fase 5). **O daemon não é tocado**
por nada descrito aqui: esta parte é apenas shell (QML) e os patches do core.

- Instalador: [`../scripts/install-shell.sh`](../scripts/install-shell.sh)
- Patch do core (drawers): [`../patches/patch-caelestia-whatsapp.py`](../patches/patch-caelestia-whatsapp.py)
- Patch da barra: [`../patches/patch-caelestia-whatsapp-bar.py`](../patches/patch-caelestia-whatsapp-bar.py)
- Patch do Nexus: [`../patches/patch-caelestia-whatsapp-nexus.py`](../patches/patch-caelestia-whatsapp-nexus.py)
- Protocolo do daemon/CLI: [`IPC.md`](IPC.md)
- Módulo QML: `shell/` deste repositório (a "lane shell", copiada para o core)
- Contrato de design de referência: `caelestia-extras/docs/PORT-SPEC-WHATSAPP-V2.md`

## 1. Visão geral

O Caelestia instalado vive em `$CAELESTIA_DIR` (default
`~/.config/quickshell/caelestia`). Os passos são idempotentes e sem `sudo`:

1. **Copia** o diretório `shell/` do repositório para
   `$CAELESTIA_DIR/extras/whatsapp/`.
2. **Patcheia** quatro ficheiros do core para instanciar e animar o `Drawer`
   do WhatsApp (`Panels.qml`, `ContentWindow.qml`, `Regions.qml`,
   `Interactions.qml`).
3. **Patcheia a barra** (`modules/bar/Bar.qml`) com o `DelegateChoice`
   `roleValue: "whatsapp"` e adiciona `{"id": "whatsapp", "enabled": true}` a
   `bar.entries` de `~/.config/caelestia/shell.json`.
4. **Patcheia o Nexus** (`PageRegistry.qml` + `PageCompRegistry.qml`) com a
   página "WhatsApp".

O módulo é importado pelo core como `qs.extras.whatsapp` (namespaced), tal como
a dock usa `qs.extras.dock`. O `extras/` do core já é uma raiz de import do
Quickshell; o subdiretório `whatsapp/` traz o seu próprio `qmldir`.

```
$CAELESTIA_DIR/
├── extras/
│   └── whatsapp/            # <- copiado de shell/ por install-shell.sh
│       ├── qmldir           #    module qs.extras.whatsapp
│       ├── WhatsAppState.qml      (singleton; IPC `whatsapp`)
│       ├── Drawer.qml             (tipo `Drawer`; contrato abaixo)
│       └── ... (modules/components/services do painel)
├── modules/
│   ├── drawers/             # <- patch-caelestia-whatsapp.py
│   │   ├── Panels.qml
│   │   ├── ContentWindow.qml
│   │   ├── Regions.qml
│   │   └── Interactions.qml
│   ├── bar/Bar.qml          # <- patch-caelestia-whatsapp-bar.py
│   └── nexus/               # <- patch-caelestia-whatsapp-nexus.py
│       ├── PageRegistry.qml
│       └── PageCompRegistry.qml
~/.config/caelestia/shell.json   # <- bar.entries (badge habilitado)
```

> O `qmldir` do módulo **tem** de declarar `module qs.extras.whatsapp`, os
> singletons (nomeadamente `WhatsAppState`) e o tipo `Drawer`. O instalador
> valida a presença de `qmldir` e avisa se o cabeçalho `module` não casar.

## 2. O que é patcheado no core

Todos os blocos são envolvidos por marcadores e aplicados de forma idempotente
(uma segunda execução é no-op). Cada ficheiro alterado ganha um backup
`.bak-<timestamp>` ao lado do original.

| Ficheiro | Patch | Alteração |
|---|---|---|
| `modules/drawers/Panels.qml` | `patch-caelestia-whatsapp.py` | `import qs.extras.whatsapp as ExtrasWhatsApp` (marcador); `readonly property alias whatsapp: whatsapp`; instância `ExtrasWhatsApp.Drawer { id: whatsapp; screen: root.screen; screenState: root.screenState; anchors.top/bottom/left: parent.* }` antes do `Sidebar.Wrapper`. |
| `modules/drawers/ContentWindow.qml` | `patch-caelestia-whatsapp.py` | `PanelBg { id: whatsappBg; panel: panels.whatsapp; deformAmount: 0.03; implicitHeight: panel.height * (1 / rawDeformMatrix.m22) + 2 }` junto aos demais; `whatsapp.transform: Matrix4x4 { matrix: whatsappBg.deformMatrix }` **dentro** do bloco `Panels`; `\|\| panels.whatsapp.visible` no binding de `WlrLayershell.keyboardFocus`. |
| `modules/drawers/Regions.qml` | `patch-caelestia-whatsapp.py` | `R { panel: root.panels.whatsapp; y: 0; height: panel.height * (1 - panel.offsetScale) + root.borderThickness }` (região de input full-height). |
| `modules/drawers/Interactions.qml` | `patch-caelestia-whatsapp.py` | Sensor de borda à **direita da barra** + dwell de 450 ms para abrir e timer de 300 ms para fechar; supressão quando `popouts.hasCurrent \|\| pressed \|\| fullscreen`; fecha ao perder o rato (`onContainsMouseChanged`) e em `onFullscreenChanged`. |
| `modules/bar/Bar.qml` | `patch-caelestia-whatsapp-bar.py` | `import qs.extras.whatsapp` + `import qs.extras.whatsapp as ExtrasWhatsApp`; `DelegateChoice { roleValue: "whatsapp"; delegate: EntryWrapper { WhatsAppBarItem { bar: root; objectName: "taskbarWhatsApp" } } }` no fim do `DelegateChooser`. |
| `~/.config/caelestia/shell.json` | `patch-caelestia-whatsapp-bar.py` | entrada `{"id": "whatsapp", "enabled": true}` em `bar.entries` (dict ou list), se o ficheiro existir. |
| `modules/nexus/PageRegistry.qml` | `patch-caelestia-whatsapp-nexus.py` | `import qs.extras.whatsapp as ExtrasWhatsApp`; página `{ label: qsTr("WhatsApp"), icon: "chat", description: qsTr("Conexão, notificações e conta"), category: "shell" }` **no fim** da lista `pages`. |
| `modules/nexus/PageCompRegistry.qml` | `patch-caelestia-whatsapp-nexus.py` | o mesmo import; `Component { StackPage { Component { ExtrasWhatsApp.WhatsAppSettingsPage {} } } }` **no fim** da lista `pageComps`. As duas listas têm de ter o mesmo tamanho. |

Marcadores usados (constantes `MARK_BEGIN`/`MARK_END` dos patches):

```
// >>> caelestia-extras whatsapp                  (drawers)
// <<< caelestia-extras whatsapp

// >>> caelestia-extras whatsapp-bar              (barra)
// <<< caelestia-extras whatsapp-bar

// >>> caelestia-extras whatsapp-native-settings  (Nexus)
// <<< caelestia-extras whatsapp-native-settings
```

### Rodar os patches isoladamente

```sh
# default: ~/.config/quickshell/caelestia
python3 patches/patch-caelestia-whatsapp.py
python3 patches/patch-caelestia-whatsapp-bar.py
python3 patches/patch-caelestia-whatsapp-nexus.py

# diretório explícito
python3 patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR"

# ver o que faria, sem tocar em nada
python3 patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR" --dry-run
python3 patches/patch-caelestia-whatsapp-bar.py "$CAELESTIA_DIR" --dry-run
python3 patches/patch-caelestia-whatsapp-nexus.py "$CAELESTIA_DIR" --dry-run

# em testes/CI, apontar o shell.json para uma cópia (não toca no real)
python3 patches/patch-caelestia-whatsapp-bar.py /tmp/core-copia \
    --shell-json /tmp/caefix/shell.json
```

Os patches validam as âncoras antes de editar: se um ficheiro ou uma âncora não
existir, imprimem `AVISO:`/`ERRO:` com o caminho exato e não escrevem lixo. Se
algum ficheiro do core faltar, saem com código diferente de zero. O patch da
barra deriva o `shell.json` de `CAELESTIA_DIR` (`~/.config/caelestia/shell.json`
para o default); fora de `~/.config` apenas avisa que o ficheiro não existe,
sem tocar em nada. Use `--shell-json PATH` para o forçar.

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
- `function show()`, `function hide()`, `function toggle()`

O `Drawer` escuta esses sinais e só age se o monitor focado for o seu
(`Hypr.focusedMonitor.name === screen.name`).

## 4. Badge na barra

O patch `patch-caelestia-whatsapp-bar.py` adiciona ao `DelegateChooser` de
`modules/bar/Bar.qml` um `DelegateChoice` com `roleValue: "whatsapp"` que
instancia `WhatsAppBarItem` (do módulo `qs.extras.whatsapp`) com `bar: root` —
o mesmo padrão do `kodexbar`/`nolimits`. O item mostra o estado/contagem de
não-lidas e, ao ser clicado, pede `WhatsAppState.toggle()` (abrindo/fechando o
`Drawer`).

A entrada correspondente é adicionada a `bar.entries` em
`~/.config/caelestia/shell.json`:

```json
{ "id": "whatsapp", "enabled": true }
```

Sem esta entrada o `DelegateChoice` existe mas o `Repeater` não itera o item
(o modelo é `Config.bar.entries.values.filter(e => e.enabled)`), pelo que o
badge não aparece. A entrada pode ser desligada (`"enabled": false`) ou
removida pela UI de Ajustes.

## 5. Página no Nexus (Ajustes)

O patch `patch-caelestia-whatsapp-nexus.py` insere **no fim** das listas
espelhadas:

- `PageRegistry.qml` → `{ label: qsTr("WhatsApp"), icon: "chat",
  description: qsTr("Conexão, notificações e conta"), category: "shell" }`;
- `PageCompRegistry.qml` → `Component { StackPage { Component {
  ExtrasWhatsApp.WhatsAppSettingsPage {} } } }`.

Inserir no fim preserva os índices das páginas existentes (a dock, por
exemplo). O script valida que as duas listas ficam com o mesmo número de
entradas antes de escrever; se divergirem, aborta sem tocar nos ficheiros.

A página cobre **conexão** (estado do daemon, QR/login/logout), **notificações**
e **conta**.

## 6. Atalho e IPC

O singleton `WhatsAppState` (em `shell/services/WhatsAppState.qml`) expõe:

- **Atalho global** `caelestia:whatsapp` via `CustomShortcut { name: "whatsapp" }`.
  Faça o bind no Hyprland, por exemplo:
  ```
  bind = SUPER, W, global, caelestia:whatsapp
  ```
- **IPC do shell** (namespace `whatsapp`):

  ```sh
  caelestia shell whatsapp toggle     # abre/fecha
  caelestia shell whatsapp show
  caelestia shell whatsapp hide
  caelestia shell whatsapp login      # inicia o pareamento (QR)
  caelestia shell whatsapp logout
  # equivalente direto no Quickshell:
  qs -c caelestia ipc call whatsapp toggle
  ```

Este IPC é o **do shell** (Quickshell) e não se confunde com o protocolo do
**daemon** `caelestia-whatsappd` (`cwctl …`, NDJSON sobre Unix socket),
documentado em [`IPC.md`](IPC.md). A ponte entre os dois é o
`WhatsAppClient`/`WhatsAppState` do módulo.

### Notificações

As notificações nativas seguem o `Notifs` do core e são alimentadas pelos
eventos do daemon (`message.received`, `chat.updated`, `auth.*` — ver
[`IPC.md`](IPC.md)). A página do Nexus permite ligar/desligar o comportamento
sem tocar no daemon. Para inspecionar o estado:

```sh
cwctl status
cwctl login     # parear (imprime o QR no terminal)
```

## 7. Instalar

```sh
# a partir da raiz do repositório caelestia-whatsapp
bash scripts/install-shell.sh                          # core default
bash scripts/install-shell.sh /caminho/para/caelestia  # core explícito
bash scripts/install-shell.sh --dry-run                # ensaio, não altera
```

Passos que o script executa (todos idempotentes):

1. valida `shell/`, o `qmldir`, os três patches, `Bar.qml`, o `modules/nexus` e o `CAELESTIA_DIR`;
2. copia `shell/` → `$CAELESTIA_DIR/extras/whatsapp/`;
3. corre `patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR"` (drawers);
4. corre `patches/patch-caelestia-whatsapp-bar.py "$CAELESTIA_DIR"` (barra + `shell.json`);
5. corre `patches/patch-caelestia-whatsapp-nexus.py "$CAELESTIA_DIR"` (Nexus);
6. imprime os próximos passos.

Reiniciar o shell para carregar o módulo:

```sh
caelestia shell -k && caelestia shell -d
```

Abrir/fechar: hover à direita da barra (dwell), clique no badge da barra, o
atalho global `caelestia:whatsapp`, ou o IPC `caelestia shell whatsapp toggle`.

## 8. Desinstalar / rollback

1. **Reverter o core** — restaurar os backups criados pelos patches (os mais
   recentes, por timestamp). Faça-o com o shell parado (`caelestia shell -k`).

   Drawers (`patch-caelestia-whatsapp.py`):

   ```sh
   cd "$CAELESTIA_DIR/modules/drawers"
   ls -1t Panels.qml.bak-* ContentWindow.qml.bak-* Regions.qml.bak-* Interactions.qml.bak-*
   # confirme os timestamps e restaure:
   cp -a Panels.qml.bak-<ts> Panels.qml
   cp -a ContentWindow.qml.bak-<ts> ContentWindow.qml
   cp -a Regions.qml.bak-<ts> Regions.qml
   cp -a Interactions.qml.bak-<ts> Interactions.qml
   ```

   Barra (`patch-caelestia-whatsapp-bar.py`):

   ```sh
   cd "$CAELESTIA_DIR/modules/bar"
   ls -1t Bar.qml.bak-* && cp -a Bar.qml.bak-<ts> Bar.qml

   # shell.json (o backup fica ao lado do ficheiro real):
   ls -1t ~/.config/caelestia/shell.json.bak-* \
     && cp -a ~/.config/caelestia/shell.json.bak-<ts> ~/.config/caelestia/shell.json
   ```

   Nexus (`patch-caelestia-whatsapp-nexus.py`):

   ```sh
   cd "$CAELESTIA_DIR/modules/nexus"
   ls -1t PageRegistry.qml.bak-* PageCompRegistry.qml.bak-*
   cp -a PageRegistry.qml.bak-<ts> PageRegistry.qml
   cp -a PageCompRegistry.qml.bak-<ts> PageCompRegistry.qml
   ```

   Em alternativa (os patches são idempotentes e reversíveis por conteúdo),
   remova manualmente os blocos entre os marcadores correspondentes:

   - `// >>> caelestia-extras whatsapp` … `// <<< caelestia-extras whatsapp`
     (drawers);
   - `// >>> caelestia-extras whatsapp-bar` … `// <<< caelestia-extras whatsapp-bar`
     (barra);
   - `// >>> caelestia-extras whatsapp-native-settings` …
     `// <<< caelestia-extras whatsapp-native-settings` (Nexus).

   No `shell.json`, remova a entrada `{"id": "whatsapp", "enabled": true}` de
   `bar.entries`. **Não** remova os marcadores da dock
   (`caelestia-extras dock-settings`) nem do `kodexbar`.

2. **Remover o módulo QML**:

   ```sh
   rm -rf "$CAELESTIA_DIR/extras/whatsapp"
   ```

3. Opcional: apagar os `.bak-*` antigos. O daemon continua a funcionar
   normalmente (não é afetado).

## 9. Migração futura para o plugin oficial (PR #1703)

O Caelestia `main` ainda **não** tem plugin system ativo; o PR **#1703**
(branch `feat/plugins`) define `manifest.json` + `entryPoints`
(`bar-entry`, `bar-popout`, `status-icon`, `quick-toggle`, `dashboard-tab`) e
passa a procurar plugins em `~/.local/share/caelestia/plugins`.

Quando esse system estabilizar, a migração **não toca no daemon nem no
protocolo IPC** (o `cwctl`/UDS mantêm-se):

1. empacotar `shell/services/WhatsAppClient.qml` + `shell/services/WhatsAppState.qml`
   + `shell/modules/whatsapp/` como um plugin (`manifest.json` com `entryPoints`
   `bar-entry`/`bar-popout`/`settings-page`);
2. deixar de copiar para `extras/whatsapp/` e de patchear
   `Panels/ContentWindow/Regions/Interactions`, `Bar.qml` e
   `PageRegistry`/`PageCompRegistry` — o plugin passa a ser descoberto em
   `~/.local/share/caelestia/plugins`;
3. manter o singleton/estado (`WhatsAppState`), o IPC `whatsapp`, o atalho
   `caelestia:whatsapp` e a API do `Drawer` (`offsetScale`/`open`/`close`) para
   não partir ligações internas.

Até lá, a via suportada é esta integração das Fases 3 e 5 (copy + patches
idempotentes).
