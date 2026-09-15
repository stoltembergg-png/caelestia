# Configuração do CachyOS Caelestia

Manifestos de configuração portáveis e documentação para um desktop CachyOS/Arch
usando uma sessão Hyprland e Caelestia. Revise os manifestos antes de instalar;
a disponibilidade dos pacotes, especialmente no AUR, deve ser verificada no momento da instalação.

Este repositório não contém credenciais, mídia pessoal, binários do host,
wallpapers, configurações de firmware, BIOS ou mudanças de Secure Boot. As ações
privilegiadas continuam interativas no Kitty ou em outro terminal visível; o projeto
nunca aceita senhas.

Consulte a [atribuição dos componentes](docs/COMPONENTS.md) e as [premissas de hardware](docs/HARDWARE.md).

## Instalação

Este repositório é privado, portanto o instalador é obtido com uma sessão `gh`
autenticada (ou um `GH_TOKEN` com acesso de leitura ao repositório):

```bash
# one-liner: clone to a temp dir and run the installer
bash -c 'tmp=$(mktemp -d) && gh repo clone stoltembergg-png/cachyos-caelestia-setup "$tmp" && bash "$tmp/install.sh"'
```

Ou clone-o primeiro e revise o plano antes de executar:

```bash
gh repo clone stoltembergg-png/cachyos-caelestia-setup
cd cachyos-caelestia-setup
./install.sh --dry-run   # review what will be done
./install.sh
```

Execute `./install.sh --help` para ver todas as opções (`--dry-run`, `--yes`, `--restore`, `--skip-monitor`).
