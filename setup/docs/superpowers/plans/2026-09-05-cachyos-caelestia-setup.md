# Plano de implementação da configuração do CachyOS Caelestia

> **Para agentes autônomos:** SUB-HABILIDADE OBRIGATÓRIA: use superpowers:subagent-driven-development (recomendado) ou superpowers:executing-plans para implementar este plano tarefa por tarefa. As etapas usam a sintaxe de caixa de seleção (`- [ ]`) para acompanhamento.

**Objetivo:** construir um repositório público e reproduzível de configuração que aplique a configuração validada do usuário para CachyOS + Hyprland + Caelestia a partir de um único comando em um terminal visível, com backups, validação em dry-run, tratamento seguro de pacotes e um relatório de saúde somente leitura.

**Arquitetura:** um entrypoint Bash delega para módulos pequenos e testáveis. Um manifesto versionado separa repositórios oficiais, AUR e fontes Flatpak. Templates sanitizados usam placeholders explícitos para caminhos dependentes da home. A instalação é transacional no nível da configuração: captura os arquivos do usuário e um pré-snapshot opcional do Snapper antes das mudanças, depois fornece um caminho explícito de restauração. Firmware de hardware, BIOS, Secure Boot, partições e estado do bootloader permanecem fora do escopo do instalador.

**Stack tecnológico:** Bash 5, `pacman`, `paru` quando disponível para AUR, `flatpak`, `snapper`, `btrfs`, `systemd`, `hyprpm`, CLI/Shell Caelestia, configuração Lua do Hyprland, ShellCheck, shfmt, Bats Core, GitHub Actions.

**Especificação:** `docs/superpowers/specs/2026-09-05-cachyos-caelestia-setup-design.md`

## Restrições globais

- [ ] Nunca invoque o Alacritty. A documentação e a verificação manual devem usar o Kitty ou o terminal já visível do usuário.
- [ ] Nunca solicite, leia, armazene, exiba ou automatize uma senha. Os comandos privilegiados permanecem interativos e são executados no terminal visível.
- [ ] Nunca altere BIOS, Secure Boot, firmware, partições de disco, bootloader ou segredos de todo o sistema.
- [ ] Não copie todo o `~/.config/fish/fish_variables` existente; gere apenas o fragmento de tema gerenciado e preserve o estado não relacionado do usuário.
- [ ] Não inclua mídia pessoal, credenciais, caminhos absolutos `/home/gabriel/...`, arquivos `.so` compilados ou identificadores específicos da máquina.
- [ ] Toda operação destrutiva ou potencialmente irreversível deve ser opt-in, explicar seu escopo e ter um alvo validado. A limpeza do cache de pacotes e a remoção de órfãos não fazem parte da configuração padrão.
- [ ] O instalador deve ser idempotente: executá-lo novamente atualiza apenas os arquivos gerenciados e não duplica linhas, serviços, atalhos de teclado, repositórios ou remotos Flatpak.
- [ ] `--dry-run` não deve mutar pacotes, arquivos, serviços, plugins ou snapshots.
- [ ] Toda configuração gerada deve passar por uma verificação de política de origem antes de ser commitada.
- [ ] Mantenha os commits pequenos e focados; cada tarefa abaixo termina com um commit revisável de forma independente.

## Mapa do repositório

A implementação estabelecerá este layout:

```text
.
├── install.sh
├── LICENSE
├── README.md
├── docs/
│   ├── COMPONENTS.md
│   ├── HARDWARE.md
│   ├── RECOVERY.md
│   └── troubleshooting.md
│   └── superpowers/
│       ├── specs/2026-09-05-cachyos-caelestia-setup-design.md
│       └── plans/2026-09-05-cachyos-caelestia-setup.md
├── config/
│   ├── caelestia/
│   │   ├── cli.json
│   │   ├── shell.json
│   │   ├── pt-BR.json
│   │   ├── monitors/DP-1/shell.json
│   │   └── local-overrides/...
│   ├── fish/
│   │   └── conf.d/caelestia-theme.fish
│   ├── hypr/
│   │   ├── config/autostart.lua
│   │   ├── config/keybinds.lua
│   │   ├── config/env.lua
│   │   ├── config/variables.lua
│   │   └── hyprland.lua
│   └── nwg-dock-hyprland/
│       ├── style.css
│       └── caelestia-dynamic.css
├── packages/
│   ├── official.txt
│   ├── aur.txt
│   └── flatpak.txt
├── lib/
│   ├── preflight.sh
│   ├── packages.sh
│   ├── config.sh
│   ├── services.sh
│   └── verify.sh
├── scripts/
│   ├── cachy-health
│   ├── restore-backup
│   ├── check-source-policy.sh
│   └── render-config.sh
└── tests/
    ├── bats/
    ├── smoke.sh
    ├── fixtures/
    └── shell/
```

O diretório exato do monitor é mantido apenas como exemplo de template; o renderizador deve detectar o nome do monitor ativo e renderizar o perfil selecionado ou ignorá-lo com uma mensagem clara quando `--skip-monitor` for usado.

---

## Tarefa 1: estabelecer manifestos, metadados e limites do repositório seguros para contribuições

**Arquivos:** `packages/official.txt`, `packages/aur.txt`, `packages/flatpak.txt`, `README.md`, `LICENSE`, `.gitignore`, `docs/COMPONENTS.md`, `docs/HARDWARE.md`, `tests/bats/manifests.bats`

- [ ] Escreva `packages/official.txt` com um pacote por linha e comentários para os grupos. Inclua os pacotes oficiais conhecidos: `fish`, `flatpak`, `fwupd`, `hyprland`, `nwg-dock-hyprland`, `pamac-aur`, `snapper`, `btrfs-progs`, `btrfs-assistant`, `bazaar`, `flameshot`, `swappy`, `playerctl`, `pavucontrol`, `cliphist`, `wl-clipboard`, `slurp`, `grim`, `wl-gammarelay-rs`, `ttf-cascadia-code-nerd` e `ttf-material-symbols-variable`.
- [ ] Escreva `packages/aur.txt` com `caelestia-cli`, `caelestia-shell`, `quickshell-git`, `qt6-m3shapes-git`, `ttf-rubik-vf` e `zen-browser-bin`, observando que a disponibilidade dos pacotes deve ser verificada, não presumida.
- [ ] Escreva `packages/flatpak.txt` com os identificadores aprovados de lojas/aplicativos GUI opcionais somente após verificar seus IDs exatos; não inclua um ID de aplicativo presumido.
- [ ] Adicione o licenciamento MIT e um arquivo de exclusões que não inclua logs, arquivos temporários renderizados, arquivos de backup, wallpapers pessoais, arquivos `.env` e artefatos de build.
- [ ] Documente a atribuição dos componentes e as premissas compatíveis em `docs/COMPONENTS.md` e `docs/HARDWARE.md`: CachyOS/Arch, sessão Hyprland, Btrfs/Snapper opcionais, Kitty ou outro terminal visível, uma sessão de desktop autenticada, o perfil `DP-1` protegido e exclusões explícitas de BIOS/CPPC/Secure Boot.
- [ ] Adicione testes Bats que rejeitem nomes de pacotes duplicados, identificadores vazios, metacaracteres de shell em identificadores de pacotes e um arquivo de manifesto ausente.

Verificação:

```bash
bats tests/bats/manifests.bats
git diff --check
```

Commit: `chore: establish setup manifests and repository policy`

## Tarefa 2: implementar o contrato compartilhado de linha de comando e a camada de execução segura

**Arquivos:** `install.sh`, `lib/preflight.sh`, `tests/smoke.sh`, `tests/bats/common.bats`, `tests/fixtures/fake-bin/`

- [ ] Implemente uma inicialização estrita do Bash (`set -Eeuo pipefail`), descoberta determinística da raiz do repositório e um workspace temporário com traps de limpeza.
- [ ] Analise `--dry-run`, `--yes`, `--restore TIMESTAMP`, `--skip-monitor`, `--help` e `--version`; rejeite opções desconhecidas e valores ausentes com código de saída 2.
- [ ] Forneça os auxiliares `log_info`, `log_warn`, `log_error`, `die`, `run`, `run_privileged` e `confirm`. No modo dry-run, `run` registra o argv exato sem executá-lo; `run_privileged` nunca incorpora uma senha nem invoca um auxiliar gráfico de senha.
- [ ] Use arrays de argumentos para execução de pacotes e comandos. Não construa comandos de pacotes por meio de `eval`, `sh -c` ou interpolação sem aspas.
- [ ] Adicione verificações preliminares para a versão do Bash, orientação sobre terminal interativo/visível, distribuição compatível, alcance da rede, disponibilidade do `sudo`, sessão de desktop e comandos básicos necessários. Torne as verificações acionáveis e diferencie falhas impeditivas de recursos opcionais.
- [ ] Garanta que `--help` e `--version` funcionem sem acesso a root, rede ou gerenciador de pacotes.
- [ ] Teste a análise de argumentos, a não execução no dry-run, a propagação do código de saída, a limpeza por sinal e a rejeição de metacaracteres de shell por meio de fixtures Bats.

Verificação:

```bash
bash -n install.sh lib/*.sh scripts/*.sh
bats tests/bats/common.bats
```

Commit: `feat: add safe installer command contract`

## Tarefa 3: adicionar instalação de pacotes com separação oficial/AUR e idempotência

**Arquivos:** `lib/packages.sh`, `tests/bats/packages.bats`, `docs/troubleshooting.md`

- [ ] Implemente a detecção de presença de pacotes com `pacman -Q`, a detecção de disponibilidade nos repositórios com `pacman -Si` e a detecção de disponibilidade no AUR por meio do auxiliar selecionado.
- [ ] Execute a atualização completa do sistema oficial (`pacman -Syu`) e instale os pacotes oficiais em uma única transação planejada, atualizando os bancos de dados apenas após confirmação ou `--yes`; nunca faça uma atualização parcial do banco de dados.
- [ ] Detecte o `paru` e use-o apenas para pacotes explicitamente listados no manifesto do AUR. Se o `paru` estiver ausente, informe os pacotes AUR exatos que precisam de tratamento manual e pare antes de uma instalação AUR parcial; não reinstale o `yay`.
- [ ] Trate um pacote opcional indisponível registrando-o como ignorado com um motivo; falhe para pacotes obrigatórios indisponíveis tanto nos repositórios configurados quanto no caminho AUR permitido.
- [ ] Mantenha os nomes dos pacotes em arrays criados a partir de linhas de manifesto validadas. Não passe comentários ou linhas vazias aos gerenciadores de pacotes.
- [ ] Adicione um resumo do plano de pacotes que separe claramente os já instalados, os que serão instalados, os opcionais indisponíveis e os pacotes impeditivos.
- [ ] Adicione testes de fixture para pacotes instalados, entradas duplicadas, pacotes indisponíveis, `paru` ausente, comportamento de dry-run e a invariável “não reintroduzir `yay`”.

Verificação:

```bash
bats tests/bats/packages.bats
shellcheck lib/packages.sh
```

Commit: `feat: install validated official and aur package sets`

## Tarefa 4: implementar backups, pré-snapshots do Snapper e restauração explícita

**Arquivos:** `lib/config.sh`, `scripts/restore-backup`, `tests/bats/snapshots.bats`, `docs/RECOVERY.md`, `docs/troubleshooting.md`

- [ ] Crie o estado em `~/.local/state/cachyos-caelestia-setup/` e os backups em `backups/<UTC-timestamp>/` com permissões restritivas.
- [ ] Antes de tocar nos arquivos gerenciados, copie cada alvo existente preservando, quando possível, os caminhos relativos e metadados; registre um manifesto com checksums e indicando se cada arquivo estava ausente.
- [ ] Detecte Btrfs e uma configuração root utilizável do Snapper. Crie um snapshot de pré-configuração rotulado somente quando ambos estiverem disponíveis e nunca trate a criação do snapshot como permissão para alterar subvolumes não relacionados.
- [ ] Se não existir configuração do Snapper, continue com os backups de arquivos e informe que a reversão ocorre apenas no nível dos arquivos.
- [ ] Implemente `--restore TIMESTAMP` em `install.sh` e `scripts/restore-backup` com validação exata do diretório de backup, confirmação salvo quando `--yes` for fornecido, restauração apenas dos alvos gerenciados e uma sugestão final de recarga/reinício. Recuse traversal de caminhos e escapes por links simbólicos.
- [ ] Torne a restauração idempotente e preserve os arquivos criados após o backup, exceto quando forem alvos gerenciados registrados explicitamente no manifesto.
- [ ] Teste os caminhos de capacidade de snapshot com `findmnt`, `snapper` e `btrfs` simulados; teste backup/restauração, timestamps inválidos, arquivos ausentes, permissões e rejeição de traversal de caminhos.

Verificação:

```bash
bats tests/bats/snapshots.bats
shellcheck lib/config.sh
```

Commit: `feat: add reversible configuration backups and restore`

## Tarefa 5: renderizar e validar templates de configuração sanitizados

**Arquivos:** `scripts/render-config.sh`, `lib/config.sh`, `config/caelestia/**`, `config/fish/conf.d/caelestia-theme.fish`, `config/hypr/**`, `config/nwg-dock-hyprland/**`, `tests/bats/render-config.bats`

- [ ] Transfira para templates apenas a configuração não pessoal aprovada pelo usuário, proveniente da configuração ativa, mantendo as traduções pt-BR funcionais, os rótulos concisos de dispositivos de áudio, a posição/alternância da porcentagem da bateria, o comportamento do seletor de wallpapers, o estilo do dock e as bordas limpas de janelas/tema.
- [ ] Substitua valores dependentes da máquina exatamente por estes placeholders compatíveis: `__HOME__`, `__WALLPAPER_DIR__` e `__HYPRFOCUS_PLUGIN__`. Use o comando `zen-browser` fornecido pelo pacote nos atalhos de teclado em vez de um caminho absoluto para um executável extraído.
- [ ] Renderize `__HOME__` a partir da home real do usuário que invoca o comando, `__WALLPAPER_DIR__` a partir de um padrão XDG com fallback para um diretório existente e `__HYPRFOCUS_PLUGIN__` somente como referência de plugin gerenciada em runtime; nunca fixe o monitor ou nome de usuário atuais no código.
- [ ] Mantenha a integração do Fish em um arquivo `conf.d` dedicado que leia o esquema Caelestia gerado ou use um fallback seguro. Não sobrescreva `fish_variables`.
- [ ] Mantenha o perfil `DP-1` atual versionado para o alvo na mesma máquina, gere/aplique-o somente após consultar as saídas ativas, preserve um padrão portátil e respeite `--skip-monitor` quando a saída não corresponder ou o usuário solicitar a omissão.
- [ ] Instale arquivos atomicamente com arquivos temporários dentro do sistema de arquivos de destino, modo `0644` para configurações comuns e `0755` para scripts executáveis, após capturar o backup.
- [ ] Adicione testes do renderizador para todos os placeholders, caminhos de home com espaços, diretórios de wallpapers ausentes, dados de monitor ausentes, ausência de caminhos absolutos `/home/`, ausência de tokens/chaves e ausência de payloads binários de plugins.

Verificação:

```bash
bats tests/bats/render-config.bats
bash scripts/check-source-policy.sh
```

Commit: `feat: render portable caelestia and hyprland configuration`

## Tarefa 6: integrar Hyprland, hyprfocus oficial, atalhos de teclado e serviços do dock

**Arquivos:** `lib/services.sh`, `config/hypr/config/autostart.lua`, `config/hypr/config/keybinds.lua`, `config/hypr/hyprland.lua`, `config/nwg-dock-hyprland/**`, `tests/bats/integrations.bats`, `docs/RECOVERY.md`, `docs/troubleshooting.md`

- [ ] Remova do template gerenciado o caminho antigo de carregamento manual `~/.config/hypr/plugins/hyprfocus.so`; nunca copie o binário incompatível da máquina atual.
- [ ] Detecte o `hyprpm`, adicione `https://github.com/hyprwm/hyprland-plugins` somente quando ausente, habilite o `hyprfocus`, execute `hyprpm update` e recarregue o plugin pelo mecanismo compatível do Hyprland. Registre um motivo claro para ignorar opcionalmente quando o suporte do Hyprland/plugin estiver indisponível.
- [ ] Preserve os padrões sutis aprovados de animação de foco e evite instalar plugins visuais como `hyprbars` ou `borders-plus-plus`.
- [ ] Restaure o atalho oficial do seletor de wallpapers do Caelestia (`SUPER+W`) usando o comando da CLI Caelestia instalado e verifique que ele não abre a página de configurações. Mantenha `SUPER+1` até `SUPER+9` mapeados para a troca de workspace.
- [ ] Substitua o caminho absoluto extraído do Zen pelo comando estável de inicialização `zen-browser` fornecido por `zen-browser-bin`.
- [ ] Instale/atualize o serviço de usuário `nwg-dock-hyprland` e seu caminho de tema dinâmico do Caelestia somente quando o serviço estiver disponível; mantenha nos templates a transparência do dock, a altura baixa da borda, o fundo com a cor do tema, a posição elevada e um feedback mais forte ao passar/clicar.
- [ ] Torne as operações de serviço de usuário explícitas e idempotentes (`systemctl --user daemon-reload`, habilitar/reiniciar apenas unidades gerenciadas). Não habilite serviços não relacionados.
- [ ] Habilite TRIM semanal, scrub mensal de Btrfs e timeline/limpeza do Snapper somente quando o sistema de arquivos, a configuração e as unidades systemd correspondentes estiverem disponíveis; informe a manutenção ignorada sem bloquear a configuração do desktop.
- [ ] Teste os caminhos do hyprpm, a ausência do plugin antigo, as strings exatas dos atalhos de teclado, a idempotência das unidades de serviço e os rastros de comandos do dry-run usando fixtures.

Verificação:

```bash
bats tests/bats/integrations.bats
shellcheck lib/services.sh
```

Commit: `feat: integrate official hyprfocus and desktop services`

## Tarefa 7: adicionar integrações de desktop e padrões de localização voltados ao usuário

**Arquivos:** `lib/services.sh`, `config/caelestia/**`, `config/fish/**`, `docs/COMPONENTS.md`, `docs/RECOVERY.md`, `tests/bats/desktop-integrations.bats`

- [ ] Configure o Flathub do usuário de forma idempotente e verifique que o escopo do remoto é `user`; não escreva remotos de todo o sistema por padrão.
- [ ] Forneça verificações de disponibilidade do Bazaar/Pamac e documente que as ações de instalação/atualização de pacotes continuam sendo confirmadas pelo usuário na GUI ou no gerenciador de pacotes.
- [ ] Instale entradas opcionais do manifesto Flatpak somente após verificar seus IDs exatos e somente depois que o remoto Flathub no nível do usuário estiver pronto; registre IDs opcionais indisponíveis sem falhar a configuração do desktop.
- [ ] Configure a tradução/overrides locais aprovados em pt-BR sem alegar suporte upstream. Mantenha as strings upstream não traduzidas visíveis em uma lista de fallback documentada, em vez de corromper o texto silenciosamente.
- [ ] Normalize os rótulos de dispositivos de áudio na camada de apresentação, preserve os nomes completos dos dispositivos em tooltips ou detalhes e mantenha a porcentagem da bateria Bluetooth atrás de uma alternância de configurações com um padrão estável.
- [ ] Mantenha a imagem central do carrossel de wallpapers sem escurecimento, escureça apenas o fundo da seleção, ofereça navegação por setas e fechamento ao clicar fora e aplique o wallpaper selecionado pelo caminho normal do Caelestia.
- [ ] Mantenha as páginas de tela de bloqueio, controles de energia, atualizações, plugins, tela, Bluetooth e wallpapers alinhadas ao tema atual e aos rótulos em português; não altere configurações de firmware ou BIOS.
- [ ] Teste a idempotência do remoto, o fallback de localização, o comportamento de truncamento/tooltip dos rótulos, a persistência da alternância e as transições de estado do seletor de wallpapers a partir de fixtures estáticas.

Verificação:

```bash
bats tests/bats/desktop-integrations.bats
```

Commit: `feat: preserve desktop integrations and pt-br defaults`

## Tarefa 8: adicionar o comando de auditoria somente leitura `cachy-health`

**Arquivos:** `scripts/cachy-health`, `lib/verify.sh`, `tests/bats/health.bats`, `docs/HARDWARE.md`, `docs/RECOVERY.md`

- [ ] Informe SO/kernel, driver/governador da CPU, ZRAM, swap, estatísticas de dispositivos Btrfs, Snapper/timers, TRIM, contagem de atualizações de pacotes, contagem de órfãos, disponibilidade de atualizações de firmware, versões do Hyprland/Caelestia e estado dos serviços de usuário.
- [ ] Classifique os achados como OK, NOTICE ou ACTION com uma explicação de remediação; não altere automaticamente uma configuração, remova pacotes, execute atualizações de firmware, habilite Secure Boot nem altere CPPC.
- [ ] Torne cada sondagem opcional e segura contra timeout, para que uma ferramenta ausente produza um aviso em vez de abortar todo o relatório.
- [ ] Suporte `--json` para scripts, mantendo o relatório padrão legível por humanos em português. Faça o escape correto do JSON e use nomes de campos estáveis.
- [ ] Adicione testes de fixture para cenários saudável, ferramenta ausente, sistema de arquivos incompatível, atualização pendente e falha de comando.

Verificação:

```bash
bats tests/bats/health.bats
shellcheck scripts/cachy-health lib/verify.sh
```

Commit: `feat: add read-only cachyos health audit`

## Tarefa 9: compor o fluxo do instalador, as barreiras de segurança e as mensagens de recuperação

**Arquivos:** `install.sh`, `lib/*.sh`, `scripts/restore-backup`, `tests/bats/installer.bats`, `tests/smoke.sh`, `tests/fixtures/`

- [ ] Componha o fluxo nesta ordem: analisar argumentos; verificações preliminares; resolver manifestos; exibir o plano; confirmar; capturar backups/snapshot; instalar pacotes; renderizar configurações; configurar integrações do usuário; configurar plugin/serviços; executar validações; exibir comandos de reversão e saúde.
- [ ] Em `--dry-run`, mostre todas as ações planejadas de pacotes, arquivos, plugins, serviços, Flatpak e snapshots sem mutar o estado nem exigir root.
- [ ] No modo normal, pare diante de falhas obrigatórias, preserve a referência do backup na mensagem de erro e nunca continue após uma transação de pacotes falha ou uma escrita atômica de configuração falha.
- [ ] Em `--yes`, suprima apenas as confirmações explicitamente listadas no plano; ainda exiba os comandos privilegiados e dependa do terminal visível para autenticação.
- [ ] Escreva um registro de execução legível por máquina contendo timestamp, versão, opções selecionadas, componentes instalados/ignorados e IDs de backup/snapshot, excluindo senhas e conteúdo de arquivos pessoais.
- [ ] Adicione testes de fixture ponta a ponta cobrindo instalação limpa, nova execução, dry-run, falha de componente opcional, falha de componente obrigatório, restauração e limpeza após interrupção.

Verificação:

```bash
bats tests/bats/installer.bats
bash -n install.sh lib/*.sh scripts/*.sh
```

Commit: `feat: compose safe idempotent setup workflow`

## Tarefa 10: adicionar CI, aplicação da política de origem e documentação para uso com um comando

**Arquivos:** `.github/workflows/ci.yml`, `scripts/check-source-policy.sh`, `.shellcheckrc`, `.editorconfig`, `README.md`, `docs/COMPONENTS.md`, `docs/HARDWARE.md`, `docs/RECOVERY.md`, `docs/troubleshooting.md`, `tests/bats/**`, `tests/smoke.sh`

- [ ] Adicione jobs de CI para sintaxe Bash, ShellCheck, verificação do shfmt, testes Bats, varredura da política de origem, validação de manifestos e `git diff --check`.
- [ ] Faça o script de política de origem falhar para caminhos absolutos `/home/`, nomes do usuário atual, chaves privadas, atribuições comuns de tokens, arquivos binários de plugins, `eval` e `sudo` sem controle; permita apenas os três placeholders documentados e nomes explícitos de comandos.
- [ ] Documente o comando público usando a URL raw versionada, explique o modelo de confiança, mostre primeiro o `--dry-run`, liste o comportamento de pacotes/AUR/Flatpak e declare as exclusões de escopo.
- [ ] Documente a recuperação com `--restore`, a descoberta de snapshots do Snapper, a recarga manual de serviços e o comando `cachy-health` somente leitura.
- [ ] Documente como contribuir com melhorias de tradução/localização upstream sem incluir screenshots pessoais, credenciais ou caminhos da máquina.
- [ ] Adicione uma checklist de release exigindo uma execução limpa do CI, uma validação em um CachyOS/Hyprland novo, uma segunda execução idempotente e uma tag de versão revisada antes de publicar a URL raw de instalação.
- [ ] Adicione `tests/smoke.sh --dry-run` como entrypoint de smoke test em uma home de fixture exigido pela especificação e execute-o no CI.

Verificação:

```bash
shellcheck install.sh lib/*.sh scripts/*.sh
shfmt -d install.sh lib scripts tests
bats tests/bats
bash scripts/check-source-policy.sh
git diff --check
```

Commit: `ci: enforce installer quality and source policy`

## Tarefa 11: validar no host ativo e publicar a primeira versão

**Arquivos:** `docs/validation/live-host-YYYY-MM-DD.md`, `README.md`, `docs/COMPONENTS.md`, `docs/HARDWARE.md`, `docs/RECOVERY.md`

- [ ] Execute o dry-run completo no host atual e compare seu plano com a configuração ativa validada: shell/CLI Caelestia, overrides pt-BR, seletor de wallpapers, dock, tema do Fish, Hyprfocus, páginas de energia, normalização dos rótulos de áudio, alternância da porcentagem do Bluetooth e atalhos de teclado dos workspaces.
- [ ] Execute o instalador real a partir de um terminal Kitty visível somente depois de revisar o plano e confirmar o caminho do backup. Não digite nem retransmita a senha do usuário.
- [ ] Verifique a sessão pós-instalação: `SUPER+W` abre o seletor de wallpapers; o comportamento de setas/clique/clique fora funciona; `SUPER+1..9` troca de workspace; dock e tema recarregam; as páginas do Caelestia permanecem em português; os rótulos de áudio continuam compactos; os metadados de restauração existem.
- [ ] Execute novamente e confirme que não há linhas de configuração, serviços, registros de plugins, transações de pacotes ou remotos Flatpak duplicados.
- [ ] Execute `cachy-health --json` e salve apenas achados sanitizados no relatório de validação; exclua nomes de usuário, números de série, caminhos pessoais e mídia.
- [ ] Revise a árvore final com `git status`, a varredura da política de origem, os resultados do CI e um diff limpo. Crie a tag `v1.0.0` somente após a validação ativa passar e o usuário autorizar explicitamente a publicação.

Verificação:

```bash
git status --short
bash scripts/check-source-policy.sh
bats tests/bats
```

Commit: `docs: record first live-host validation`

## Checklist final de autorrevisão

- [ ] Cada requisito da especificação aprovada tem uma tarefa de implementação e um comando de verificação.
- [ ] O manifesto de pacotes não duplica `caelestia-cli`; ele aparece apenas na lista AUR, salvo se a verificação no repositório ativo provar o contrário.
- [ ] Nenhuma tarefa copia `fish_variables`, o `hyprfocus.so` antigo, o binário Zen extraído, wallpapers, credenciais ou identificadores de hardware.
- [ ] `SUPER+W`, atalhos dos workspaces, comportamento do dock, localização em português, integração do tema e porcentagem opcional da bateria Bluetooth são todos cobertos por testes ou por uma verificação explícita no host ativo.
- [ ] O comportamento de restauração, o comportamento de dry-run, a visibilidade dos comandos privilegiados e o comportamento de falha do AUR são inequívocos.
- [ ] Procure placeholders de planejamento inacabados e caminhos suspeitos:

```bash
rg -n 'TODO|TBD|FIXME|/home/gabriel|/home/|BEGIN (RSA|OPENSSH) PRIVATE KEY|token|password|secret' . --glob '!docs/superpowers/specs/**' --glob '!docs/superpowers/plans/**'
git diff --check
```

- [ ] Confirme que o próprio arquivo de plano não contém texto-placeholder, nenhum comando destrutivo sem limites e nenhuma instrução para manipular senhas.
