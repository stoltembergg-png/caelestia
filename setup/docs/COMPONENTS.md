# Componentes e atribuição

A plataforma-alvo é o CachyOS, uma distribuição baseada em Arch, com uma sessão
de desktop Hyprland autenticada. Caelestia, Quickshell, nwg-dock-hyprland, Fish,
Pamac, Flatpak/Flathub, Bazaar, Snapper, Btrfs, fwupd e o ecossistema oficial de
plugins do Hyprland continuam sendo componentes upstream; este repositório fornece
apenas uma seleção documentada e metadados de perfil portáveis.

A configuração pressupõe o Kitty ou outro terminal visível para operações
privilegiadas interativas. Ela nunca usa Alacritty nem manipula senhas. É necessário
um usuário comum com sudo e acesso à rede. Btrfs e Snapper são opcionais e
só são usados quando já estão disponíveis.
