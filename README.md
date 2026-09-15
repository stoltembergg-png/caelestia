# caelestia

**Um workspace de desktop Linux para ferramentas nativas, integrações de shell e configuração reproduzível.**

[![Linux](https://img.shields.io/badge/Linux-111827?style=flat-square&logo=linux&logoColor=white)](https://www.linux.org/)
[![Wayland](https://img.shields.io/badge/Wayland-111827?style=flat-square&logo=wayland&logoColor=white)](https://wayland.freedesktop.org/)
[![Go](https://img.shields.io/badge/Go-111827?style=flat-square&logo=go&logoColor=white)](https://go.dev/)
[![QML](https://img.shields.io/badge/QML-111827?style=flat-square&logo=qt&logoColor=white)](https://doc.qt.io/qt-6/qmlapplications.html)
[![AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-111827?style=flat-square)](LICENSE)

`caelestia` reúne as partes funcionais de um ambiente de desktop Linux: uma integração nativa com WhatsApp, complementos de shell, uma configuração reproduzível do CachyOS e camadas pessoais focadas sobre projetos upstream.

## Comece aqui

- [Integração com WhatsApp](whatsapp/README.md) — daemon, CLI e interface Quickshell.
- [Complementos de shell](extras/README.md) — Quick Actions, Dock, mecanismo de cota e painel do WhatsApp.
- [Configuração do CachyOS](setup/README.md) — manifestos de pacotes e instalador protegido.

## Mapa de diretórios

| Diretório | Linguagem / tecnologia | Finalidade |
|---|---|---|
| [`whatsapp/`](whatsapp/) | Go, QML, Quickshell, SQLite | WhatsApp nativo para Caelestia, usando um daemon whatsmeow e um socket de domínio Unix. |
| [`extras/`](extras/) | QML, Quickshell | Complementos do Caelestia portados do Serpantinum. |
| [`setup/`](setup/) | Shell, CachyOS, Hyprland | Configuração reproduzível com manifestos de pacotes oficiais e AUR. |
| [`custom/serpantinum/`](custom/serpantinum/) | QML, unified diff | Camada pessoal sobre `ilyamiro/serpantinum`, com material de procedência e regeneração. |
| [`custom/shell/`](custom/shell/) | Git format-patch | Série de patches de contribuição para `caelestia-dots/shell`. |

## Componentes do workspace

### `whatsapp/`

Caelestia-whatsapp fornece uma integração nativa com WhatsApp: um daemon Go whatsmeow, a CLI `cwctl` e uma UI QML/Quickshell sobre um socket de domínio Unix. Usa serviços de usuário do systemd e armazenamento SQLite, sem WebView, Chromium ou Electron.

Consulte o [README do WhatsApp](whatsapp/README.md) para instalação e uso.

### `extras/`

Caelestia-extras contém complementos de shell portados do Serpantinum: Quick Actions com Notepad e o quadro branco “Lousa”, um Dock, o mecanismo de cota No Limits do KodexBar e um painel do WhatsApp.

Consulte o [README dos extras](extras/README.md) para instalação e uso.

### `setup/`

Esta é a configuração reproduzível do CachyOS + Hyprland + Caelestia. Ela contém manifestos de pacotes oficiais e AUR, além de um instalador seguro com suporte a `--dry-run` e `--restore` e ações privilegiadas interativas.

Esta subárvore era privada antes de entrar no monorepo público. Revise os scripts e as mudanças planejadas antes de instalar.

Consulte o [README da configuração](setup/README.md) para obter detalhes da instalação.

## Modelo de integração

- **UI do shell:** Quickshell e QML fornecem as interfaces voltadas ao desktop e os complementos.
- **Serviço do WhatsApp:** o daemon Go gerencia o WhatsApp por meio do whatsmeow; a CLI e a UI usam seu socket de domínio Unix.
- **Configuração do sistema:** CachyOS e Hyprland são descritos por manifestos de pacotes e um instalador protegido.
- **Mudanças pessoais:** as diferenças em relação ao upstream são mantidas como arquivos modificados ou uma série explícita de format-patch, em vez de um fork oculto separado.

## Histórico e procedência

Os diretórios `whatsapp/`, `extras/` e `setup/` preservam o histórico completo das subárvores de seus repositórios originais.

Os diretórios custom documentam sua relação com o upstream, em vez de apresentar as camadas como projetos independentes. Use os arquivos `UPSTREAM.md` incluídos para entender a procedência e regenerar as mudanças rastreadas.

## Camadas pessoais vs. upstream

O diretório `custom/` separa as mudanças pessoais dos projetos upstream que elas estendem:

- **[`custom/serpantinum/`](custom/serpantinum/)** contém apenas arquivos modificados em relação ao merge-base de [`ilyamiro/serpantinum`](https://github.com/ilyamiro/serpantinum), além de `serpantinum-custom.patch` e `UPSTREAM.md`. O patch registra o unified diff completo e `UPSTREAM.md` explica a procedência e a regeneração.
- **[`custom/shell/`](custom/shell/)** contém uma série de format-patch para branches de contribuição sobre [`caelestia-dots/shell`](https://github.com/caelestia-dots/shell), abrangendo a largura do popout de áudio da barra, a quebra do clima no dashboard e erros PAM localizados na tela de bloqueio. Também inclui evidências de PR e `UPSTREAM.md`.

O repositório raiz é licenciado sob [AGPL-3.0](LICENSE). O material do Serpantinum é baseado no upstream AGPL-3.0; a série de patches do shell tem como alvo um upstream GPL-3.0. Esses termos de licença e a procedência do upstream continuam fazendo parte do contexto quando o workspace combinado é usado ou redistribuído.

## Projetos upstream

- [`caelestia-dots/shell`](https://github.com/caelestia-dots/shell) — o shell GPL-3.0 que recebe a série de patches de contribuição.
- [`ilyamiro/serpantinum`](https://github.com/ilyamiro/serpantinum) — o shell AGPL-3.0 usado como base da camada pessoal.

## Licença

A raiz do monorepo está sob [AGPL-3.0](LICENSE). Consulte os arquivos `UPSTREAM.md` incluídos e os repositórios upstream para conhecer a procedência e os termos upstream aplicáveis.
