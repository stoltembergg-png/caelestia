#!/usr/bin/env bash
#
# install-shell.sh — instala o módulo QML nativo do WhatsApp no core do
# Caelestia e reaplica o patch dos drawers (Fase 3 do caelestia-whatsapp).
#
# O que faz (idempotente, SEM sudo):
#   1. copia shell/ do repositório para $CAELESTIA_DIR/extras/whatsapp/
#      (incluindo o qmldir próprio: `module qs.extras.whatsapp`);
#   2. roda patches/patch-caelestia-whatsapp.py "$CAELESTIA_DIR" para ligar o
#      Drawer ao core (Panels/ContentWindow/Regions/Interactions);
#   3. imprime os próximos passos (reiniciar o shell, atalho, cwctl).
#
# Uso:
#   scripts/install-shell.sh [CAELESTIA_DIR] [--dry-run] [--help]
#
# CAELESTIA_DIR default: $CAELESTIA_DIR se definido, senão
# ~/.config/quickshell/caelestia.
#
# Não toca no daemon nem no protocolo IPC. Ver docs/INTEGRATION.md.
set -euo pipefail

# ---------------------------------------------------------------------------
# Saída / erros
# ---------------------------------------------------------------------------
info()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[ok]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Uso: scripts/install-shell.sh [CAELESTIA_DIR] [--dry-run] [--help]

Copia o módulo QML `shell/` do repositório para
$CAELESTIA_DIR/extras/whatsapp/ e aplica o patch idempotente do core
(modules/drawers/{Panels,ContentWindow,Regions,Interactions}.qml).

Argumentos:
  CAELESTIA_DIR   diretório do core Caelestia.
                  Default: $CAELESTIA_DIR, senão ~/.config/quickshell/caelestia
  --dry-run       não copia nem altera ficheiros; só reporta (encaminhado para
                  o patch)

Não usa sudo. Não toca no daemon do WhatsApp.
EOF
}

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
DRY_RUN=0
POSITIONAL=()
for arg in "$@"; do
	case "$arg" in
		-h|--help) usage; exit 0 ;;
		--dry-run) DRY_RUN=1 ;;
		-*) die "argumento desconhecido: $arg (veja --help)" ;;
		*) POSITIONAL+=("$arg") ;;
	esac
done

if [ "${#POSITIONAL[@]}" -gt 1 ]; then
	die "demasiados argumentos: apenas um CAELESTIA_DIR é aceito (veja --help)"
fi

# ---------------------------------------------------------------------------
# Localização do repositório (script fica em <repo>/scripts/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"

SHELL_SRC="$REPO_ROOT/shell"
PATCH="$REPO_ROOT/patches/patch-caelestia-whatsapp.py"

CAELESTIA_DIR="${POSITIONAL[0]:-${CAELESTIA_DIR:-$HOME/.config/quickshell/caelestia}}"
CAELESTIA_DIR="${CAELESTIA_DIR/#\~/$HOME}"
DRAWERS_DIR="$CAELESTIA_DIR/modules/drawers"
EXTRAS_DIR="$CAELESTIA_DIR/extras"
TARGET_DIR="$EXTRAS_DIR/whatsapp"

# ---------------------------------------------------------------------------
# Validação (mensagens claras antes de tocar em nada)
# ---------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || die "'python3' não encontrado no PATH"

info "repositório: $REPO_ROOT"
info "core:        $CAELESTIA_DIR"
info "destino:     $TARGET_DIR"
[ "$DRY_RUN" -eq 1 ] && info "modo:        dry-run (nada será alterado)"

[ -d "$SHELL_SRC" ] || die "módulo QML não encontrado: $SHELL_SRC (lane shell/ ainda não foi criada?)"
[ -f "$SHELL_SRC/qmldir" ] || die "qmldir do módulo não encontrado: $SHELL_SRC/qmldir"
if ! grep -q '^module[[:space:]]\+qs\.extras\.whatsapp[[:space:]]*$' "$SHELL_SRC/qmldir"; then
	warn "$SHELL_SRC/qmldir não declara exatamente 'module qs.extras.whatsapp'"
	warn "o import `qs.extras.whatsapp` do core pode não resolver"
fi
[ -f "$PATCH" ] || die "patch não encontrado: $PATCH"
[ -d "$DRAWERS_DIR" ] || die "não encontrei os drawers do core: $DRAWERS_DIR (CAELESTIA_DIR correto?)"

# ---------------------------------------------------------------------------
# 1. Copiar o módulo QML (idempotente)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
	n_files="$(find "$SHELL_SRC" -type f | wc -l)"
	info "copiaria $n_files ficheiro(s) de $SHELL_SRC para $TARGET_DIR (dry-run)"
else
	mkdir -p "$TARGET_DIR"
	cp -a "$SHELL_SRC/." "$TARGET_DIR/"
	[ -f "$TARGET_DIR/qmldir" ] || die "cópia falhou: $TARGET_DIR/qmldir não existe"
	n_files="$(find "$TARGET_DIR" -type f | wc -l)"
	ok "módulo QML copiado -> $TARGET_DIR ($n_files ficheiro(s))"
fi

# ---------------------------------------------------------------------------
# 2. Aplicar o patch do core (idempotente)
# ---------------------------------------------------------------------------
info "a aplicar patch do core…"
if [ "$DRY_RUN" -eq 1 ]; then
	python3 "$PATCH" "$CAELESTIA_DIR" --dry-run
else
	python3 "$PATCH" "$CAELESTIA_DIR"
fi
ok "patch do core concluído"

# ---------------------------------------------------------------------------
# 3. Próximos passos
# ---------------------------------------------------------------------------
cat <<EOF

Instalação do shell concluída (nada foi reiniciado automaticamente).

Próximos passos:

  1) Reiniciar o Caelestia para carregar o módulo:
       caelestia shell -k && caelestia shell -d

  2) Abrir/fechar o painel:
       - hover à direita da barra (dwell de ~450 ms), ou
       - atalho global \`caelestia:whatsapp\` (se existir na sua config Hyprland), ou
       - pelo binding IPC/Hyprland equivalente.

  3) Estado do daemon (não é tocado por este script):
       cwctl status
       cwctl login     # parear (imprime o QR no terminal)

Desinstalar: ver docs/INTEGRATION.md (remover extras/whatsapp e restaurar
os .bak-* do core).
EOF
