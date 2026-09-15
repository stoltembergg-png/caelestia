#!/usr/bin/env bash
# Instala os extras (Quick Actions, Dock, No Limits, WhatsApp) num fork do Caelestia Shell.
# Uso: ./install.sh [CAELESTIA_DIR]     (default: ~/.config/quickshell/caelestia)
#
# O que faz:
#   1. copia src/extras/ para $CAELESTIA_DIR/extras
#   2. adiciona um Loader idempotente em $CAELESTIA_DIR/shell.qml (com backup)
#   3. adiciona o pragma EnableQtWebEngineQuick em shell.qml (necessário p/ o WhatsApp)
#   4. instala o wrapper scripts/qs em ~/.local/bin/qs (usa o build patchado do Quickshell)
#   5. aplica o patch opcional da barra (entrada "kodexbar") e migra dados do Serpantinum
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
STAMP="$(date +%Y%m%d%H%M%S)"

if [ ! -f "$SHELL_QML" ]; then
  echo "ERRO: não encontrei '$SHELL_QML'." >&2
  echo "Passe o diretório do fork do Caelestia: ./install.sh /caminho/para/quickshell/caelestia" >&2
  exit 1
fi
if [ ! -d "$SRC_DIR" ]; then
  echo "ERRO: '$SRC_DIR' não existe (repo incompleto)." >&2
  exit 1
fi

# 1. extras
mkdir -p "$DEST"
cp -r "$SRC_DIR/." "$DEST/"
echo "extras copiados para: $DEST"

# 2. Loader
if grep -qF "$MARK_BEGIN" "$SHELL_QML"; then
  echo "shell.qml: Loader já presente (nada a fazer)."
elif [ "$(printf '%s' "$(tail -n 1 "$SHELL_QML")" | tr -d '[:space:]')" = "}" ]; then
  cp "$SHELL_QML" "$SHELL_QML.bak-$STAMP"
  TMP="$SHELL_QML.tmp.$$"
  head -n -1 "$SHELL_QML" > "$TMP"
  printf '%s\n%s\n%s\n' "$MARK_BEGIN" "$LOADER_LINE" "$MARK_END" >> "$TMP"
  echo "}" >> "$TMP"
  mv "$TMP" "$SHELL_QML"
  echo "shell.qml: Loader inserido (backup .bak-$STAMP)."
else
  echo "AVISO: shell.qml não termina com '}'." >&2
  echo "Adicione manualmente, DENTRO do root ShellRoot:" >&2
  echo "  $LOADER_LINE" >&2
  exit 2
fi

# 4. wrapper qs (build patchado com WebView)
mkdir -p "$HOME/.local/bin"
QS_DST="$HOME/.local/bin/qs"
if [ -f "$QS_DST" ]; then
  cp -a "$QS_DST" "$QS_DST.bak-$STAMP"
  echo "~/.local/bin/qs existente salvo em qs.bak-$STAMP."
fi
if [ -f "$REPO_DIR/scripts/qs" ]; then
  install -m 755 "$REPO_DIR/scripts/qs" "$QS_DST"
  echo "wrapper qs instalado em $QS_DST (usa ~/.local/opt/quickshell-webview; fallback /usr/bin/qs)."
else
  echo "AVISO: scripts/qs ausente; instale depois manualmente (ver docs/QUICKSHELL-WEBVIEW.md)." >&2
fi

# 5. patches opcionais do core (barra, dock, Nexus) + migração (melhor esforço)
if command -v python3 >/dev/null 2>&1; then
  for p in bar dock nexus; do
    python3 "$REPO_DIR/scripts/patch-caelestia-$p.py" "$DEST_ROOT" \
      || echo "AVISO: patch '$p' não aplicado; rode depois: python3 scripts/patch-caelestia-$p.py \"$DEST_ROOT\"" >&2
  done
else
  echo "AVISO: python3 ausente; patches do core não aplicados." >&2
fi

if [ -f "$REPO_DIR/scripts/migrate-serpantinum.sh" ]; then
  bash "$REPO_DIR/scripts/migrate-serpantinum.sh" || true
fi

cat <<'EOF'

Pronto. Passos finais:
- Reinicie o shell:  qs -c caelestia kill   (ou reinicie a sessão)
- Atalhos (Hyprland/Lua):
    hl.dsp.global("caelestia:quickactions")   hl.dsp.global("caelestia:dock")
    hl.dsp.global("caelestia:nolimits")
- IPC:  qs -c caelestia ipc call extras toggleQuickActions | setQuickActionsTab <n> |
        toggleDock | toggleNoLimits
- Config: ~/.config/caelestia/extras.json (criado com defaults na 1ª execução)
- Docs: docs/INTEGRATION.md (smoke test) e docs/SWITCH-PLAN.md (troca do Serpantinum)

Importante (1º boot): depois de rodar o Caelestia uma vez, reaplique:
  python3 scripts/patch-caelestia-bar.py "$CAELESTIA_DIR"   # shell.json só existe após o 1º boot
  bash scripts/migrate-serpantinum.sh                        # extras.json idem

Notas:
- O módulo WhatsApp WebView foi REMOVIDO; a integração nativa vive no repo
  caelestia-whatsapp (daemon Go + UDS), ver docs/ARQUITETURA.md de lá.
- Se o Caelestia foi instalado via CMake (e não clonado como fork), o CMake não copia a
  pasta extras/ — nesse caso rode o Caelestia a partir do fork em ~/.config/quickshell/caelestia.
EOF
