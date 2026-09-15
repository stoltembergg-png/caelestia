#!/usr/bin/env bash
# Serpantinum WhatsApp toggle — abre/foca o wrapper Tauri whatsapp-linux
# Uso: whatsapp-toggle.sh [toggle|launch|focus]
set -u
MODE="${1:-toggle}"

find_bin() {
  if command -v whatsapp-linux >/dev/null 2>&1; then command -v whatsapp-linux; return 0; fi
  for c in \
    "$HOME/.local/bin/whatsapp-linux" \
    "$HOME/Documentos/Default Project/whatsapp-linux/src-tauri/target/release/whatsapp-linux" \
    "/usr/bin/whatsapp-linux" \
    "/usr/local/bin/whatsapp-linux"; do
    if [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

is_running() { pgrep -x "whatsapp-linux" >/dev/null 2>&1; }

focus_win() {
  # Hyprland
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && command -v hyprctl >/dev/null 2>&1; then
    hyprctl dispatch focuswindow "class:com.whatsapp.linux" >/dev/null 2>&1 && return 0
    hyprctl dispatch focuswindow "class:whatsapp-linux" >/dev/null 2>&1 && return 0
    hyprctl dispatch focuswindow "title:WhatsApp" >/dev/null 2>&1 && return 0
  fi
  # Niri
  if command -v niri >/dev/null 2>&1 && [ -n "${NIRI_SOCKET:-}" ]; then
    niri msg action focus-window --app-id "com.whatsapp.linux" >/dev/null 2>&1 && return 0
  fi
  # Sway
  if command -v swaymsg >/dev/null 2>&1 && [ -n "${SWAYSOCK:-}" ]; then
    swaymsg '[app_id="com.whatsapp.linux"] focus' >/dev/null 2>&1 && return 0
  fi
  return 1
}

launch() {
  BIN="$(find_bin || true)"
  if [ -n "${BIN:-}" ]; then
    nohup "$BIN" >/dev/null 2>&1 &
    disown || true
    return 0
  fi
  # Fallback: abre o Web no navegador padrão
  xdg-open "https://web.whatsapp.com" >/dev/null 2>&1 &
  return 0
}

case "$MODE" in
  launch) launch ;;
  focus) focus_win || launch ;;
  *) # toggle
    if is_running; then
      focus_win || true
      # single-instance do Tauri já foca ao relançar; tenta relançar leve
      BIN="$(find_bin || true)"
      [ -n "${BIN:-}" ] && nohup "$BIN" >/dev/null 2>&1 &
    else
      launch
    fi
    ;;
esac
