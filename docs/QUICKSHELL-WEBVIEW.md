# Quickshell WebView (patch `EnableQtWebEngineQuick`)

Build patchado do [Quickshell](https://github.com/quickshell-mirror/quickshell) que
permite usar `WebEngineView` do QtWebEngine sem que o Quickshell linke/instancie a
QtWebEngineQuick no startup. É a base do port do widget de WhatsApp ([W1](PORT-SPEC-WHATSAPP.md)).

## Por que existe

O Quickshell stock **não inicializa a QtWebEngineQuick**, então `WebEngineView` em QML
falha com comportamento indefinido. A QtWebEngine exige que
`QtWebEngineQuick::initialize()` seja chamado no processo **antes** de qualquer engine
QQml/QGuiApplication, porque ela precisa configurar atributos gráficos e o
`QCoreApplication` de forma própria (por isso o `qArgC` deixa de ser `0`).

O patch adiciona uma inicialização **dinâmica e opt-in**:

- só acontece quando o arquivo de configuração (`shell.qml`) declara
  `//@ pragma EnableQtWebEngineQuick`;
- carrega a biblioteca via `QLibrary("Qt6WebEngineQuick")` e resolve o símbolo
  mangled `_ZN16QtWebEngineQuick10initializeEv` (`void QtWebEngineQuick::initialize()`),
  evitando linkar a QtWebEngine no build e mantendo o Quickshell leve quando o
  recurso não é usado;
- se a lib/símbolo não existir, apenas loga um aviso e segue — o shell continua
  funcionando (o `WebEngineView` é que ficaria indefinido);
- como a chamada é feita por `QLibrary`, não há dependência de link e o binário
  continua rodando em ambientes sem QtWebEngine instalado.

### O que o patch contém

| Arquivo | Mudança |
| --- | --- |
| `src/webengine/webengine.hpp` | **novo**. `qs::web_engine::init()` via `QLibrary` + `resolve` + logs; `printNotLoaded()`. |
| `src/webengine/CMakeLists.txt` | **novo**. Adiciona os testes quando `BUILD_TESTING`. |
| `src/webengine/test/*` | **novos**. Teste unitário do `init()`. |
| `src/CMakeLists.txt` | adiciona `add_subdirectory(webengine)`. |
| `src/launch/launch.cpp` | parse do pragma `EnableQtWebEngineQuick`; `bool useQtWebEngineQuick`; chama `web_engine::init()` antes de criar o `QGuiApplication`; `qArgC` `0` → `1`. |
| `build.sh` | script de build original do autor, preservado no patch. |

## Rev-base e compatibilidade com o Caelestia

```
2d3b3e9c70ef380dff751b61d334dc88df016c29
```

Esse é o `origin/master` do Quickshell no momento do rebase e **coincide com o master
exigido pelo Caelestia** (o relatório de versão do binário do sistema confirma
`revision 2d3b3e9c70ef380dff751b61d334dc88df016c29`). Como o patch só adiciona o
mecanismo do pragma e não altera a API usada pelo Caelestia, o build permanece
A/B-compatível com o shell.

## Como buildar

Somente pelos scripts deste repositório (não construir dentro de um checkout sujo):

```bash
scripts/build-quickshell-webview.sh
```

O script:

1. obtém um clone do Quickshell no rev-base (`~/.local/src/quickshell-webview-build`);
2. restaura o rev-base (`git reset --hard` + `git clean`) e aplica
   `patches/quickshell-webview.patch` (com `git apply --check` antes);
3. configura com CMake e instala em `~/.local/opt/quickshell-webview`:

   | Opção | Valor |
   | --- | --- |
   | `CMAKE_BUILD_TYPE` | `RelWithDebInfo` |
   | `INSTALL_QML_PREFIX` | `lib/qt6/qml` |
   | `USE_JEMALLOC` | `OFF` (evita crash com QtWebEngine) |
   | `BUILD_TESTING` | `OFF` |
   | `CRASH_REPORTER` | `OFF` |

O script é **idempotente** (restaura o rev-base, reaplica o patch e rebuilda a cada
execução) e aceita `QS_WEBVIEW_PREFIX`, `QS_WEBVIEW_WORKDIR`, `QS_WEBVIEW_JOBS` e
`QUICKSHELL_GIT_URL` para sobrescrever os padrões.

Validação estática do patch contra o rev-base:

```bash
git clone --no-checkout https://github.com/quickshell-mirror/quickshell.git /tmp/qs
git -C /tmp/qs checkout 2d3b3e9c70ef380dff751b61d334dc88df016c29
git -C /tmp/qs apply --check patches/quickshell-webview.patch
```

## Como usar

```bash
scripts/qs ...
```

`scripts/qs` executa `~/.local/opt/quickshell-webview/bin/quickshell`, exportando
`QML2_IMPORT_PATH`/`QML_IMPORT_PATH` para `.../lib/qt6/qml`. Se o prefixo não existir,
cai automaticamente para `/usr/bin/qs` (Quickshell stock). Para ativar o WebEngine, o
`shell.qml` do Caelestia precisa da linha:

```qml
//@ pragma EnableQtWebEngineQuick
```

## Origem, licença e artefatos

- **Quickshell**: Copyright (C) Quickshell contributors — **GPL-3.0**. Clone/build a
  partir do upstream; este repositório não redistribui código do Quickshell.
- **Patch** (`patches/quickshell-webview.patch`): autoria do usuário, mesma licença
  GPL-3.0 por ser derivado do Quickshell.
- **Binários não são versionados**: o prefixo de instalação
  (`~/.local/opt/quickshell-webview`) fica fora do git. Este repositório guarda apenas
  o patch, os scripts e a documentação.
- O wrapper do autor em `~/.local/bin/quickshell` é opcional; a rota suportada é
  `scripts/qs`.
