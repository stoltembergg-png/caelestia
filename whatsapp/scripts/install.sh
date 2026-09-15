#!/usr/bin/env bash
#
# install.sh — instalador local (sem sudo) do caelestia-whatsapp.
#
# Compila o daemon e a CLI, copia para ~/.local/bin, prepara o diretório de
# dados e instala o systemd user service. NÃO habilita/inicia o serviço
# automaticamente: ao final imprime os comandos para você fazer isso.
#
# Uso:
#   scripts/install.sh
#   scripts/install.sh --help
#
# Idempotente: pode ser reexecutado (sobrescreve binários e unit).
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
Uso: scripts/install.sh [--help]

Compila caelestia-whatsappd e cwctl para ~/.local/bin, cria o diretório de
dados (~/.local/share/caelestia-whatsapp, 0700) e instala o unit de usuário
em ~/.config/systemd/user/caelestia-whatsapp.service.

Não usa sudo e não ativa o serviço automaticamente.
EOF
}

case "${1:-}" in
	-h|--help) usage; exit 0 ;;
	"") ;;
	*) die "argumento desconhecido: $1 (veja --help)" ;;
esac

# ---------------------------------------------------------------------------
# Localização do repositório (script fica em <repo>/scripts/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"

# HOME real da conta (pode diferir de $HOME em testes/CI/sandboxes).
# Quando $HOME é alternativo, ignoramos XDG_* herdado do home real para que a
# instalação fique inteiramente contida no HOME informado.
REAL_HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 || true)"
if [ -n "$REAL_HOME" ] && [ "$HOME" != "$REAL_HOME" ]; then
	unset XDG_DATA_HOME XDG_CONFIG_HOME
fi

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

BIN_DIR="$HOME/.local/bin"
DATA_DIR="$DATA_HOME/caelestia-whatsapp"
UNIT_DIR="$CONFIG_HOME/systemd/user"
UNIT_SRC="$REPO_ROOT/systemd/caelestia-whatsapp.service"
UNIT_DST="$UNIT_DIR/caelestia-whatsapp.service"

info "repositório: $REPO_ROOT"
info "HOME:        $HOME"
info "binários:    $BIN_DIR"
info "dados:       $DATA_DIR"
info "unit:        $UNIT_DST"

# ---------------------------------------------------------------------------
# Ferramentas
# ---------------------------------------------------------------------------
command -v go >/dev/null 2>&1 || die "'go' não encontrado no PATH (instale o toolchain Go 1.26+ e garanta ~/.local/bin no PATH)"
info "go: $(command -v go) ($(go version 2>/dev/null || echo 'versão desconhecida'))"

[ -d "$REPO_ROOT/daemon" ]    || die "diretório não encontrado: $REPO_ROOT/daemon"
[ -d "$REPO_ROOT/cli/cwctl" ] || die "diretório não encontrado: $REPO_ROOT/cli/cwctl"
[ -f "$UNIT_SRC" ]            || die "unit não encontrado: $UNIT_SRC"

# Em HOME alternativo (teste/CI), o cache de módulos do Go default ($HOME/go)
# costuma estar vazio. Usa o cache do home real para não baixar tudo de novo.
if [ -n "$REAL_HOME" ] && [ "$REAL_HOME" != "$HOME" ]; then
	if [ -z "${GOMODCACHE:-}" ] && [ ! -d "$HOME/go/pkg/mod" ] && [ -d "$REAL_HOME/go/pkg/mod" ]; then
		export GOMODCACHE="$REAL_HOME/go/pkg/mod"
		info "GOMODCACHE: usando cache do home real ($GOMODCACHE)"
	fi
	export GOCACHE="${GOCACHE:-$REAL_HOME/.cache/go-build}"
fi

# ---------------------------------------------------------------------------
# Diretórios (idempotente)
# ---------------------------------------------------------------------------
install -d -m 0755 "$BIN_DIR"  || die "não foi possível criar $BIN_DIR"
install -d -m 0755 "$UNIT_DIR" || die "não foi possível criar $UNIT_DIR"
install -d -m 0700 "$DATA_DIR" || die "não foi possível criar $DATA_DIR"
chmod 0700 "$DATA_DIR" 2>/dev/null || true
ok "diretórios prontos"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
info "compilando daemon (daemon/cmd/caelestia-whatsappd)…"
if ! ( cd "$REPO_ROOT/daemon" && go build -o "$BIN_DIR/caelestia-whatsappd" ./cmd/caelestia-whatsappd ); then
	die "falha ao compilar o daemon"
fi
ok "daemon -> $BIN_DIR/caelestia-whatsappd"

info "compilando CLI (cli/cwctl)…"
if ! ( cd "$REPO_ROOT/cli/cwctl" && go build -o "$BIN_DIR/cwctl" . ); then
	die "falha ao compilar a CLI cwctl"
fi
ok "cwctl  -> $BIN_DIR/cwctl"

# ---------------------------------------------------------------------------
# systemd unit
# ---------------------------------------------------------------------------
install -m 0644 "$UNIT_SRC" "$UNIT_DST" || die "falha ao instalar o unit em $UNIT_DST"
ok "unit instalado: $UNIT_DST"

if command -v systemctl >/dev/null 2>&1; then
	if systemctl --user daemon-reload; then
		ok "systemctl --user daemon-reload"
	else
		warn "systemctl --user daemon-reload falhou (user manager indisponível?); rode manualmente depois"
	fi
else
	warn "systemctl não encontrado; pulei o daemon-reload"
fi

# ---------------------------------------------------------------------------
# Próximos passos (não ativamos o serviço de propósito)
# ---------------------------------------------------------------------------
cat <<EOF

Instalação concluída. Próximos passos (nada foi iniciado automaticamente):

  1) (se ~/.local/bin não estiver no PATH)
       export PATH="\$HOME/.local/bin:\$PATH"

  2) Habilitar e iniciar o daemon:
       systemctl --user enable --now caelestia-whatsapp.service

  3) Conferir o estado:
       systemctl --user status caelestia-whatsapp.service
       cwctl status

  4) Parear o WhatsApp (imprime o QR no terminal):
       cwctl login

Logs: journalctl --user -u caelestia-whatsapp.service -f
Ajuda/erros: docs/TROUBLESHOOTING.md
EOF
