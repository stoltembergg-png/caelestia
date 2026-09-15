> [!IMPORTANT]
> **Build customizado privado.** Este fork adiciona recursos pessoais (monitor No Limits, painel do WhatsApp, Notes, widgets do KodexBar) sobre o Serpantinum upstream.
> Instalação (requer um `gh` autenticado; repositório privado):
>
> ```bash
> bash -c 'tmp=$(mktemp -d) && gh repo clone stoltembergg-png/serpantinum-custom "$tmp" && bash "$tmp/install/local-deploy.sh"'
> ```
>
> O script faz uma implantação limpa em `~/.local/share/serpantinum`, atualiza os links simbólicos de `~/.local/bin` e reinicia o daemon.
> As dependências (sessão Hyprland, build do Quickshell) vêm de `stoltembergg-png/cachyos-caelestia-setup`.
>
> Para atualizar: use `cd` em um checkout, execute `git merge upstream/master` e depois `./install/local-deploy.sh`.

<div align="center">
  <a href="https://ko-fi.com/ilyamiro">
    <img src="https://ko-fi.com/img/githubbutton_sm.svg" alt="ko-fi" />
  </a>
</div>

<div align="center">
  <img src="docs/assets/banner.png" alt="Serpantinum" width="850" />
</div>

## Pré-visualizações

| | |
|---|---|
| ![Prévia 1](docs/assets/previews/preview_1.png) | ![Prévia 2](docs/assets/previews/preview_2.png) |
| ![Prévia 3](docs/assets/previews/preview_3.png) | ![Prévia 4](docs/assets/previews/preview_4.png) |

---

## Instalação

> [!IMPORTANT]
> **Migração da v1:** Toda a configuração anterior será armazenada em backup e deixará de ser usada. A configuração de opções do compositor, como monitores, atalhos de teclado e inicialização automática, agora é responsabilidade sua, pois o projeto migrou de dotfiles para um shell.

### Arch Linux e seus derivados

Para distribuições baseadas em Arch (incluindo systemd, OpenRC e outros sistemas de inicialização), execute o script de instalação automatizada:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ilyamiro/serpantinum/master/install/install.sh)"

```

> [!NOTE]
> Para atualizar, quando receber uma notificação de que uma nova versão está disponível, execute o script novamente e escolha “update”.

---

### NixOS

Serpantinum fornece outputs de flake, um módulo NixOS para dependências do sistema e um módulo Home Manager para configuração do usuário e gerenciamento de serviços.

#### 1. Adicione a entrada do Flake

Adicione o Serpantinum ao seu `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    serpantinum.url = "github:ilyamiro/serpantinum";
  };

  outputs = { self, nixpkgs, serpantinum, ... }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit serpantinum; };
      modules = [
        ./configuration.nix
        serpantinum.nixosModules.default
      ];
    };
  };
}

```

#### 2. configuration.nix

Habilite o módulo NixOS para configurar os pré-requisitos do sistema:

```nix
{
  programs.serpantinum.enable = true;
}

```

Se preferir instalar o pacote diretamente, sem o módulo do sistema:

```nix
{ pkgs, serpantinum, ... }:

{
  environment.systemPackages = [
    serpantinum.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}

```

#### 3. Configuração do Home Manager

```nix
{ serpantinum, ... }:

{
  imports = [
    serpantinum.homeManagerModules.default
  ];

  programs.serpantinum = {
    enable = true;
    systemd.enable = true;

    settings = {
      wallpaperDir = "/home/username/Pictures/Wallpapers";

      general = {
        language = "en";
        weatherUnit = "metric";
        weatherInterval = 30;
      };

      bar = {
        position = "top";
        style = "solid";
        width = 40;
        workspaceCount = 10;
        modules = {
          left = [ "workspaces" ];
          center = [ "time" ];
          right = [ "tray" [ "kb" "wifi" "bt" "vol" "bat" ] ];
        };
      };

      theme = {
        fontFamily = "Adwaita Mono";
        borderRadius = 12;
        matugen = true;
      };

      notifications = {
        dnd = false;
        position = "top right";
        sound = true;
      };
    };
  };
}

```

#### 4. Atualização

Atualize o lockfile do flake e recompile o sistema:

```bash
nix flake update serpantinum
sudo nixos-rebuild switch --flake .

```

> **Nota:** O instalador automático gerencia a integração com o compositor em distribuições padrão. No NixOS / Home Manager, você deve integrar manualmente as configurações do compositor.
> Exemplos de configurações, entradas de inicialização automática e atalhos de teclado para gerenciadores de janelas e compositores compatíveis estão disponíveis no diretório [compositors](https://github.com/ilyamiro/serpantinum/tree/master/compositors).


#### Inicialização automática obrigatória

Lembre-se de adicionar os listeners da área de transferência e os serviços necessários à configuração de inicialização automática do compositor para que a área de transferência e o equalizador funcionem corretamente.

Exemplo no Hyprland:

```lua
hl.on("hyprland.start", function()
  hl.exec_cmd("wl-paste --type text --watch cliphist store")
  hl.exec_cmd("wl-paste --type image --watch cliphist store")
  hl.exec_cmd("systemctl --user enable --now easyeffects")
end)

```
---

## Execução

Para executar o shell, inicie `serpantinumd start`

---

## Créditos

* Agradecimentos especiais a Darkall44/Qylock por fornecer um belo tema material para SDDM!

---

## Licença

Copyright (C) 2026 Illia Miroshnichenko

Este projeto é licenciado sob a GNU Affero General Public License versão 3 ou, a seu critério, qualquer versão posterior. Consulte o arquivo [LICENSE.md](LICENSE.md) para obter o texto completo da licença.
