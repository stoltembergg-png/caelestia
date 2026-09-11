# Runbook — Trocar Serpantinum por Caelestia (+ extras)

Baseado no recon do estado atual (set/2026). **Ordem:** só executar depois dos ports (QA, Dock, NoLimits, WhatsApp) estarem revisados e no repo.

## Estado atual (resumo)

- Shell atual: `~/.config/hypr/config/autostart.lua:8` → `hl.exec_cmd("serpantinumd start")` → `quickshell -p …/serpantinum/src/quickshell/Shell.qml` (wrapper `~/.local/bin/quickshell` → build patchado WebView em `~/.local/opt/quickshell-webview`).
- Caelestia **desinstalado** (pacman removeu `caelestia-shell`+`caelestia-cli` em 09/09). Pacotes em cache: `~/.cache/yay/{caelestia-shell,caelestia-cli,libcava,qt6-m3shapes-git,ttf-rubik-vf}`.
- Backup pré-Serpantinum: `~/.config/hypr_backup/backup_20260909_192643_pre_serpantinum/` (configs hypr + `quickshell_snapshot/caelestia/` com a árvore local do shell e tokens).
- `qs` = `/usr/bin/qs` (stock, sem WebView). O WhatsApp exige o binário patchado → wrapper `~/.local/bin/qs` (entregue pelo repo).

## Fase 0 — Backup (antes de qualquer edição)

```bash
cp -a ~/.config/hypr/config ~/.config/hypr/config.serpantinum.$(date +%F_%H%M%S)
```

## Fase 1 — Instalar pacotes (não afeta a sessão)

```bash
# do cache (offline)
sudo pacman -U ~/.cache/yay/libcava/libcava-1.0.0-1-x86_64.pkg.tar.zst
sudo pacman -U ~/.cache/yay/qt6-m3shapes-git/qt6-m3shapes-git-r41.32ad9ce-1-x86_64.pkg.tar.zst
sudo pacman -U ~/.cache/yay/ttf-rubik-vf/ttf-rubik-vf-2.3.0-3-any.pkg.tar.zst
sudo pacman -U ~/.cache/yay/caelestia-cli/caelestia-cli-1.1.2-1-any.pkg.tar.zst
sudo pacman -U ~/.cache/yay/caelestia-shell/caelestia-shell-2.4.0-1-x86_64.pkg.tar.zst
# dependências fora do cache (precisam de rede)
paru -S --needed aubio libqalculate qt6-imageformats python-pillow python-materialyoucolor dart-sass fuzzel ttf-material-symbols-variable ttf-cascadia-code-nerd
```

## Fase 1b — Árvore local do shell + extras

O Caelestia roda a partir de `~/.config/quickshell/caelestia` (necessário para carregar `extras/`):

```bash
mkdir -p ~/.config/quickshell
cp -a ~/.config/hypr_backup/backup_20260909_192643_pre_serpantinum/quickshell_snapshot/caelestia \
      ~/.config/quickshell/caelestia
cd ~/caelestia-extras && ./install.sh ~/.config/quickshell/caelestia   # (após atualização do install.sh)
```

## Fase 2 — Testar na sessão atual

```bash
serpantinumd stop          # para o shell atual; Hyprland segue vivo
caelestia shell            # foreground p/ ver erros; Ctrl+C aborta
# validar: barra, drawers, atalhos, extras (QA/Dock/NoLimits/WhatsApp)
caelestia shell -d         # se OK, deixa em background
```

## Fase 3 — Tornar permanente

1. `~/.config/hypr/config/autostart.lua`: trocar `serpantinumd start` por `caelestia shell -d`.
2. `~/.config/hypr/config/keybinds.lua`: restaurar os binds `caelestia …` do backup e adicionar:
   - `hl.dsp.global("caelestia:quickactions")`
   - `hl.dsp.global("caelestia:dock")`
   - `hl.dsp.global("caelestia:nolimits")`
   - `hl.dsp.global("caelestia:whatsapp")`
3. `hyprctl reload` (keybinds valem já; o autostart só no próximo login).
4. Garantir `~/.local/bin` à frente no PATH e o wrapper `qs` instalado (repo → `~/.local/bin/qs`), pois o CLI do Caelestia chama `qs`.

## Rollback (a qualquer momento)

```bash
caelestia shell kill        # ou qs -c caelestia kill
serpantinumd start          # volta o shell imediatamente
cp -a ~/.config/hypr/config.serpantinum.<stamp>/. ~/.config/hypr/config/ && hyprctl reload
# pacotes: sudo pacman -Rns caelestia-shell caelestia-cli  (cuidado: deps compartilhadas)
```

## Checklist de validação pós-troca

- [ ] `qs -c caelestia` usa o binário patchado (`~/.local/bin/qs`); WebEngine inicializa com o pragma no `shell.qml`.
- [ ] `caelestia shell -s` lista o target `extras`.
- [ ] Quick Actions (Notas/Lousa), Dock, No Limits (abas/notificação), WhatsApp (login persistido em `…/QtWebEngine/serpantinum-whatsapp-v2`).
- [ ] Sem erros nos logs (`journalctl --user -f` / log do `qs`).

## Riscos conhecidos

- **Keybinds**: o Serpantinum reescreveu `keybinds.lua`; restaurar do backup pode reativar binds de workspace antigos — revisar antes do reload.
- **Ícone do launcher/barra**: widgets na barra dependem do patch opcional (`DelegateChoice`), aplicado pelo `install.sh` com backup.
- **pt-BR**: `contrib/caelestia-ptbr/apply-local.sh` está quebrado (chama `~/.local/bin/caelestia-ptbr-sync` inexistente); o snapshot do backup já parece conter a camada pt.
