# caelestia-extras

Add-ons para o [Caelestia Shell](https://github.com/caelestia-dots/shell), portados do [Serpantinum](https://github.com/ilyamiro/serpantinum): **Quick Actions** (Notas + Lousa), **Dock**, **No Limits** (KodexBar) e **WhatsApp**.

Status: port completo; validação **estática** (sem runtime do Caelestia) — smoke test no fim. Alvo: Caelestia `main` @ `d8ee1e8` (2026-09-11) + Quickshell **git master** (para o WhatsApp, o build patchado com WebView).

## Componentes

| Componente | Origem (Serpantinum) | O que é |
|---|---|---|
| Quick Actions | `quickactions/Floating.qml` + `actions/{Notepad,NotesList,DrawAction}.qml` + `singletons/NotesManager.qml` | Overlay por borda com abas: **Notas** e **Lousa** (`DrawAction`, canvas infinito) |
| Dock | `dock/Dock.qml` | Dock de apps (autohide, hover-magnify, reorder, picker, min-strip) |
| No Limits | `singletons/NoLimits.qml` + `kodexbar/KodexBarPopup.qml` + `bar/modules/KodexBarWidget.qml` | Motor de quotas (KodexBar) + ai-memory, popup com 4 abas, notificações e cápsula opcional na barra |
| WhatsApp | `whatsapp/WhatsAppPopup.qml` + `bar/modules/WhatsAppWidget.qml` | Painel WebEngine com sessão persistida, tema injetado e gestão de RAM; exige o Quickshell patchado (WebView) |

## Estrutura

```
src/extras/
  compat/        shims: ThemeBackend->Colours/Tokens, Scaler, Config->extras.json, Caching->Paths, I18n, ...
  reusables/     IconButton, ClickButton, DeleteButton, Input
  quickactions/  host + Notas + Lousa (+ Notas backend)
  dock/          dock (monólito portado)
  nolimits/      singleton + popup + overlay + cápsula da barra
  whatsapp/      overlay + painel WebEngine
  scripts/       md_render.py, ai-memory-probe.sh, minimize.sh
  assets/        i18n (en/pt)
patches/         quickshell-webview.patch (build patchado exigido pelo WhatsApp)
scripts/         build-quickshell-webview.sh, qs, patch-caelestia-bar.py, migrate-serpantinum.sh
install.sh
docs/
```

## Instalação

```bash
git clone https://github.com/stoltembergg-png/caelestia-extras.git
cd caelestia-extras
./install.sh                      # ou: ./install.sh /caminho/do/quickshell/caelestia
```

O `install.sh` copia `src/extras/`, insere o `Loader` no `shell.qml`, adiciona o pragma `EnableQtWebEngineQuick`, instala o wrapper `qs` (build patchado), aplica o patch opcional da barra (`kodexbar`) e migra dados do Serpantinum — tudo idempotente e com backups.

Para o WhatsApp, garanta o build patchado: `./scripts/build-quickshell-webview.sh` (ver `docs/QUICKSHELL-WEBVIEW.md`).

## Licença e procedência

Os componentes derivam do **Serpantinum** (AGPL-3.0). Este repositório é **AGPL-3.0** (ver `LICENSE`); combinado com o Caelestia (GPL-3.0), a distribuição combinada deve atender à **AGPL-3.0**. O patch do Quickshell deriva do upstream (GPL-3.0).

Detalhes: `docs/IDENTIFICATION.md`, `docs/PORT-SPEC*.md`, `docs/INTEGRATION.md` e `docs/SWITCH-PLAN.md` (troca do Serpantinum).
