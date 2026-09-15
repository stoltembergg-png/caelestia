# Configuração do CachyOS Caelestia — Projeto

## Objetivo

Criar um repositório público de perfil pessoal que restaure o desktop atual de
CachyOS + Hyprland de Gabriel após uma instalação limpa do CachyOS. O usuário deve
poder colar um comando documentado em um terminal, autenticar-se por meio do
`sudo` e obter o mesmo desktop centrado no Caelestia sem copiar credenciais, mídia
pessoal ou configurações de firmware.

## Escopo

A configuração instala e configura:

- Pacotes CachyOS/Arch e pacotes AUR selecionados.
- Caelestia Shell, CLI Caelestia, Quickshell, tradução local pt-BR e os
  overrides locais atuais do Caelestia.
- Configuração Lua do Hyprland, perfil atual do monitor, integração do dock,
  Fish e o plugin oficial `hyprfocus` de
  `https://github.com/hyprwm/hyprland-plugins`, instalado através do `hyprpm` para
  a versão instalada do Hyprland.
- Zen Browser a partir do pacote CachyOS `zen-browser-bin`, com seu launcher
  referenciado pelo nome em vez do executável extraído manualmente atual.
- Estilo do `nwg-dock-hyprland` e integração dinâmica de cores do Caelestia.
- Pamac para Arch/AUR, Flatpak com Flathub e Bazaar para descoberta de Flatpaks.
- Manutenção de Btrfs/Snapper, TRIM semanal, scrub mensal e auditoria do `fwupd`.
- Um comando `cachy-health` somente leitura que informa atualizações de pacotes,
  snapshots, scrub do Btrfs, TRIM, ZRAM e disponibilidade de firmware.

O repositório não altera opções da BIOS, chaves de Secure Boot, governadores da CPU,
firmware, partições de disco, usuários, senhas ou configuração do bootloader.

## Alvo e pré-requisitos

O alvo é uma sessão CachyOS recém-instalada com Hyprland na mesma máquina. O
instalador requer acesso à rede, um usuário comum com `sudo` e uma configuração
de pacotes CachyOS existente. O comportamento de Btrfs/Snapper é habilitado
somente quando esses recursos já estão disponíveis; o backup da configuração do
usuário está sempre disponível.

O perfil padrão inclui a configuração atual do monitor `DP-1` para recriar esta
máquina exatamente. O README avisa que outro layout de monitor exige editar ou
ignorar esse perfil.

## Interface de instalação

O comando principal do README baixa um instalador de uma release com tag:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stoltembergg-png/cachyos-caelestia-setup/v1.0.0/install.sh)
```

O README também documenta uma alternativa de clonar e revisar. O comando padrão
é atualizado apenas para novas releases com tag; ele nunca aponta para `main`.

`install.sh` oferece suporte a:

- sem argumentos: instalação interativa;
- `--dry-run`: exibir todas as ações pretendidas de pacotes, arquivos e serviços;
- `--yes`: aceitar a confirmação final da configuração depois que o usuário tiver revisado o comando documentado;
- `--restore <timestamp>`: restaurar o backup de configuração correspondente;
- `--skip-monitor`: não aplicar o perfil de monitor `DP-1`.

O script valida o CachyOS, o alcance da rede, os comandos necessários e o
`sudo` antes de qualquer operação que altere o estado. Ele nunca aceita senhas
como argumentos, variáveis de entrada ou variáveis de ambiente.

## Layout do repositório

```text
cachyos-caelestia-setup/
├── install.sh
├── lib/
│   ├── preflight.sh
│   ├── packages.sh
│   ├── config.sh
│   ├── services.sh
│   └── verify.sh
├── config/
│   ├── caelestia/
│   ├── hypr/
│   ├── nwg-dock-hyprland/
│   └── fish/
├── packages/
│   ├── official.txt
│   ├── aur.txt
│   └── flatpak.txt
├── scripts/
│   ├── cachy-health
│   └── restore-backup
├── docs/
│   ├── COMPONENTS.md
│   ├── HARDWARE.md
│   ├── RECOVERY.md
│   └── superpowers/specs/2026-09-05-cachyos-caelestia-setup-design.md
└── tests/
    ├── smoke.sh
    └── fixtures/
```

## Fluxo de instalação

1. As verificações preliminares identificam o ambiente CachyOS, verificam a rede,
   validam o `sudo` e exibem o perfil selecionado.
2. Um backup com timestamp é criado em
   `~/.local/state/cachyos-caelestia-setup/backups/<timestamp>/` para cada
   destino que já exista.
3. Se o sistema de arquivos raiz for Btrfs e existir a configuração `root` do
   Snapper, um snapshot pré-instalação será criado. A ausência de Btrfs ou Snapper
   nunca bloqueia a etapa de configuração do desktop.
4. `pacman` executa uma atualização completa do sistema e instala os pacotes
   oficiais. `paru` só é usado depois de sua presença ser confirmada para instalar
   o manifesto AUR explícito. O instalador não usa uma atualização parcial do banco
   de dados.
5. O Flatpak é configurado com o remoto Flathub no nível do usuário e as entradas
   opcionais do manifesto são instaladas.
6. Templates de configuração versionados são copiados para `~/.config`. O
   instalador substitui apenas valores de runtime aprovados, como `$HOME`, o
   diretório de imagens XDG, o caminho do plugin e o caminho opcional do executável
   Zen. As operações de cópia preservam backups e nunca publicam o diretório home
   absoluto da máquina de origem. O atalho do Zen usa o executável fornecido pelo
   pacote e é omitido com uma mensagem clara quando esse pacote opcional é ignorado.
7. `hyprpm update`, `hyprpm add https://github.com/hyprwm/hyprland-plugins`,
   `hyprpm enable hyprfocus` e `hyprpm reload -n` instalam e carregam o plugin
   oficial. O repositório nunca armazena o binário `.so` específico do host.
8. Os serviços de usuário para a integração do dock/tema e os timers do sistema
   para TRIM, limpeza/timeline do Snapper e scrub do Btrfs são habilitados quando
   suas dependências estão presentes.
9. A verificação informa versões dos pacotes, alvos de configuração, estado dos
   serviços, estado do remoto Flatpak e a ação necessária de logout/login.

## Política de captura da configuração

O projeto versiona apenas configuração portável e wallpapers padrão do Caelestia.
Antes de adicionar arquivos-fonte, uma verificação de captura rejeita:

- caminhos absolutos do diretório home que não sejam placeholders aprovados;
- chaves SSH, cabeçalhos de chaves privadas, valores semelhantes a tokens e nomes
  comuns de arquivos de credenciais;
- artefatos binários específicos do host, incluindo `hyprfocus.so`.

Os placeholders aprovados são `__HOME__`, `__WALLPAPER_DIR__` e
`__HYPRFOCUS_PLUGIN__`; o instalador os substitui por valores derivados do
ambiente do usuário-alvo ou ignora o plugin opcional quando indisponível. A
configuração do Zen usa um nome de comando estável fornecido pelo pacote
`zen-browser-bin` e não codifica um caminho do diretório home.

O perfil atual do monitor é versionado intencionalmente porque o principal caso
de uso é este mesmo sistema. Ele é isolado para que `--skip-monitor` seja exato e
reversível.

## Backup e recuperação

`--restore <timestamp>` restaura os destinos de configuração a partir do backup
selecionado e reinicia apenas os serviços de usuário relevantes após confirmação.
Ele nunca exclui um backup. `docs/RECOVERY.md` descreve a restauração manual, a
desativação de um serviço de usuário, a seleção de um snapshot Btrfs no Limine e
a remoção do perfil a partir de um TTY de recuperação.

## Confiabilidade e verificação

O projeto condiciona a publicação a:

- `bash -n` para cada script de shell;
- `shellcheck` com apenas exclusões estreitas e documentadas;
- `shfmt -d`;
- `tests/smoke.sh --dry-run` em um diretório home de fixture;
- validação de manifestos para duplicatas e sintaxe de nomes de pacotes;
- varreduras da política de captura para credenciais, `/home/gabriel` e artefatos binários;
- uma checklist manual de instalação limpa do CachyOS antes de criar a tag de uma release.

Os erros identificam o módulo que falhou e deixam o backup intacto. O instalador
para diante de um erro inesperado; nunca informa como bem-sucedido um módulo
aplicado parcialmente.

## Documentação e atribuição

`README.md` apresenta a instalação com um comando, o caminho de clonar e revisar,
o escopo compatível, a recuperação rápida e screenshots adicionadas somente após
uma validação de instalação limpa. `docs/COMPONENTS.md` atribui CachyOS, Hyprland,
Caelestia, Quickshell, nwg-dock-hyprland, Fish, Pamac, Flatpak, Flathub, Bazaar,
Snapper, Btrfs, fwupd e hyprfocus. `docs/HARDWARE.md` explica o perfil do monitor,
o CPPC opcional e por que BIOS/Secure Boot/firmware são excluídos.

## Licença

O repositório usa a Licença MIT. As licenças upstream continuam aplicáveis aos
respectivos projetos e não são relicenciadas por este repositório.
