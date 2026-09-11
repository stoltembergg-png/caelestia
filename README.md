# caelestia-extras

Add-ons para o [Caelestia Shell](https://github.com/caelestia-dots/shell): **Quick Actions** (Notas + Lousa) e um **Dock**, portados do [Serpantinum](https://github.com/ilyamiro/serpantinum) para rodar dentro de um fork do Caelestia.

Status: **em desenvolvimento (port)**. Alvo: Caelestia `main` @ `d8ee1e8` (2026-09-11) + Quickshell **git master**.

## Componentes

| Componente | Origem (Serpantinum) | O que é |
|---|---|---|
| Quick Actions | `quickactions/Floating.qml` + `actions/{Notepad,NotesList,DrawAction}.qml` + `singletons/NotesManager.qml` | Overlay por borda com abas. Neste port: **Notas** e **Lousa** (`DrawAction`, canvas infinito) |
| Dock | `dock/Dock.qml` | Dock de apps (autohide, hover-magnify, reorder, picker, min-strip) |

## Estrutura (planejada)

```
caelestia-extras/
  src/
    compat/        # camada de adaptação: ThemeBackend->Colours/Tokens, Scaler, Config->JSON, Caching->Paths, I18n, ...
    quickactions/  # host do overlay + Notas + Lousa
    dock/          # dock nativo (refatorado do monólito)
  install.sh       # copia para $CAELESTIA_DIR e aplica as edições mínimas
  docs/            # identificação, mapa de acoplamentos e plano de integração
```

## Instalação (futuro)

A ser documentada em `docs/INTEGRATION.md` e automatizada por `install.sh`. Alvo padrão: `~/.config/quickshell/caelestia`.

## Licença e procedência

Os componentes derivam do **Serpantinum** (AGPL-3.0). Este repositório é **AGPL-3.0** (ver `LICENSE`). Ao ser combinado com o Caelestia (GPL-3.0), a distribuição combinada deve atender à **AGPL-3.0**. `docs/IDENTIFICATION.md` traz o mapa completo de arquivos, dependências e o plano de port.
