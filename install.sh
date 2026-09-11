#!/usr/bin/env bash
# Instala os extras (Quick Actions + Dock) num fork do Caelestia Shell.
# Uso: ./install.sh [CAELESTIA_DIR]     (default: ~/.config/quickshell/caelestia)
#
# O que faz:
#   1. copia src/extras/ para $CAELESTIA_DIR/extras
#   2. adiciona um Loader idempotente em $CAELESTIA_DIR/shell.qml (com backup)
#
# Licença: AGPL-3.0 (derivado do Serpantinum).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$REPO_DIR/src/extras"
DEST_ROOT="${1:-$HOME/.config/quickshell/caelestia}"
DEST="$DEST_ROOT/extras"
SHELL_QML="$DEST_ROOT/shell.qml"
MARK_BEGIN="// >>> caelestia-extras"
MARK_END="// <<< caelestia-extras"
LOADER_LINE='Loader { source: "extras/Extras.qml"; asynchronous: true }'

if [ ! -f "$SHELL_QML" ]; then
  echo "ERRO: não encontrei '$SHELL_QML'." >&2
  echo "Passe o diretório do fork do Caelestia: ./install.sh /caminho/para/quickshell/caelestia" >&2
  exit 1
fi
if [ ! -d "$SRC_DIR" ]; then
  echo "ERRO: '$SRC_DIR' não existe (repo incompleto)." >&2
  exit 1
fi

mkdir -p "$DEST"
cp -r "$SRC_DIR/." "$DEST/"
echo "extras copiados para: $DEST"

if grep -qF "$MARK_BEGIN" "$SHELL_QML"; then
  echo "shell.qml já contém o Loader (nada a fazer)."
elif [ "$(printf '%s' "$(tail -n 1 "$SHELL_QML")" | tr -d '[:space:]')" = "}" ]; then
  cp "$SHELL_QML" "$SHELL_QML.bak-$(date +%Y%m%d%H%M%S)"
  TMP="$SHELL_QML.tmp.$$"
  head -n -1 "$SHELL_QML" > "$TMP"
  printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$LOADER_LINE" "$MARK_END" >> "$TMP"
  echo "}" >> "$TMP"
  mv "$TMP" "$SHELL_QML"
  echo "Loader inserido em shell.qml (backup criado)."
else
  echo "AVISO: shell.qml não termina com '}'." >&2
  echo "Adicione manualmente, DENTRO do root ShellRoot:" >&2
  echo "  $LOADER_LINE" >&2
  exit 2
fi

cat <<'EOF'

Pronto. Passos finais:
- Reinicie o shell:  qs -c caelestia kill  (ou reinicie a sessão)
- Atalhos (Hyprland/Lua): hl.dsp.global("caelestia:quickactions") e hl.dsp.global("caelestia:dock")
- IPC:  qs -c caelestia ipc call extras toggleQuickActions | setQuickActionsTab <n> | toggleDock
        (ou: caelestia shell extras toggleQuickActions)
- Config: ~/.config/caelestia/extras.json (criado com defaults na 1ª execução)
- Ver docs/INTEGRATION.md para o smoke test e desinstalação.

Nota: se o Caelestia foi instalado via CMake (e não clonado como fork), o CMake não copia a
pasta extras/ — nesse caso rode o Caelestia a partir do fork em ~/.config/quickshell/caelestia.
EOF
