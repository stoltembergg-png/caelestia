#!/usr/bin/env bash
# Deploy limpo deste checkout para ~/.local/share/serpantinum e reinicia o daemon.
# Funciona como primeira instalação (cria symlinks em ~/.local/bin) ou atualização.
# Uso: ./install/local-deploy.sh
set -Eeuo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DST="${SERPANTINUM_INSTALL_DIR:-$HOME/.local/share/serpantinum}"
BIN_DIR="${SERPANTINUM_BIN_DIR:-$HOME/.local/bin}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/serpantinum"

log() { printf '[local-deploy] %s\n' "$*"; }

STOP_DAEMON=""
if [ -x "$BIN_DIR/serpantinumd" ]; then
  STOP_DAEMON="$BIN_DIR/serpantinumd"
elif [ -x "$DST/bin/serpantinumd" ]; then
  STOP_DAEMON="$DST/bin/serpantinumd"
fi

if [ -n "$STOP_DAEMON" ]; then
  log "parando daemon (se ativo)"
  "$STOP_DAEMON" stop >/dev/null 2>&1 || true
  sleep 1
fi

log "copiando $SRC -> $DST"
rm -rf "$DST"
mkdir -p "$DST/bin" "$DST/src"
cp -r "$SRC/bin/." "$DST/bin/"
cp -r "$SRC/src/." "$DST/src/"

chmod +x "$DST/bin/"* 2>/dev/null || true
find "$DST/src/scripts" -type f -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

log "atualizando symlinks em $BIN_DIR"
mkdir -p "$BIN_DIR"
ln -sf "$DST/bin/serpantinum" "$BIN_DIR/serpantinum"
ln -sf "$DST/bin/serpantinumd" "$BIN_DIR/serpantinumd"

log "atualizando versão"
mkdir -p "$STATE"
VER="$(cat "$SRC/version.txt" 2>/dev/null || echo unknown)"
COMMIT="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
TID="$(grep -oP 'TELEMETRY_ID="\K[^"]+' "$STATE/version" 2>/dev/null || true)"
TELE="$(grep -oP 'ENABLE_TELEMETRY="\K[^"]+' "$STATE/version" 2>/dev/null || echo true)"
COMP="$(grep -oP 'SELECTED_COMPOSITORS="\K[^"]+' "$STATE/version" 2>/dev/null || echo hyprland)"
{
  printf 'SERPANTINUM_VERSION="%s"\n' "$VER"
  printf 'SERPANTINUM_COMMIT="%s"\n' "$COMMIT"
  printf 'TELEMETRY_ID="%s"\n' "$TID"
  printf 'ENABLE_TELEMETRY="%s"\n' "$TELE"
  printf 'SELECTED_COMPOSITORS="%s"\n' "$COMP"
} > "$STATE/version"

log "iniciando daemon"
setsid nohup "$BIN_DIR/serpantinumd" start >/dev/null 2>&1 </dev/null &
log "ok: versão $VER ($COMMIT)"
