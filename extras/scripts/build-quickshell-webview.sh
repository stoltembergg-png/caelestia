#!/usr/bin/env bash
#
# build-quickshell-webview.sh — build reprodutível do Quickshell com o patch de
# WebView (init dinâmica da QtWebEngineQuick via pragma EnableQtWebEngineQuick).
#
# O que faz:
#   1. Obtém um clone do Quickshell (quickshell-mirror/quickshell, GPL-3.0) no
#      rev-base fixado abaixo.
#   2. Aplica patches/quickshell-webview.patch (autoria do usuário).
#   3. Configura e compila com CMake e instala em ~/.local/opt/quickshell-webview.
#
# É idempotente: rodar de novo restaura o rev-base, reaplica o patch e rebuilda
# (reaproveitando o cache do CMake quando possível).
#
# Variáveis de ambiente (todas opcionais):
#   QS_WEBVIEW_PREFIX   prefixo de instalação   (padrão: ~/.local/opt/quickshell-webview)
#   QS_WEBVIEW_WORKDIR  diretório de trabalho    (padrão: ~/.local/src/quickshell-webview-build)
#   QS_WEBVIEW_JOBS     paralelismo do build     (padrão: nproc)
#   QUICKSHELL_GIT_URL  URL do repositório       (padrão: https://github.com/quickshell-mirror/quickshell.git)
#
set -euo pipefail

BASE_REV="2d3b3e9c70ef380dff751b61d334dc88df016c29"
GIT_URL="${QUICKSHELL_GIT_URL:-https://github.com/quickshell-mirror/quickshell.git}"
PREFIX="${QS_WEBVIEW_PREFIX:-$HOME/.local/opt/quickshell-webview}"
WORK_DIR="${QS_WEBVIEW_WORKDIR:-$HOME/.local/src/quickshell-webview-build}"
JOBS="${QS_WEBVIEW_JOBS:-$(nproc 2>/dev/null || echo 4)}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
PATCH="$REPO_ROOT/patches/quickshell-webview.patch"

log() { printf '[qs-webview] %s\n' "$*"; }
die() { printf '[qs-webview] ERRO: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git não encontrado no PATH"
command -v cmake >/dev/null 2>&1 || die "cmake não encontrado no PATH"
[[ -f "$PATCH" ]] || die "patch não encontrado: $PATCH"

# Gerador: Ninja é preferível; sem ele, o gerador padrão do CMake.
GENERATOR=()
if command -v ninja >/dev/null 2>&1; then
	GENERATOR=(-G Ninja)
fi

log "rev-base : $BASE_REV"
log "work dir : $WORK_DIR"
log "prefixo  : $PREFIX"

# 1. Clone/árvore de trabalho no rev-base.
if [[ -d "$WORK_DIR/.git" ]]; then
	log "reutilizando clone existente"
else
	log "clonando $GIT_URL"
	rm -rf "$WORK_DIR"
	mkdir -p "$(dirname -- "$WORK_DIR")"
	git clone --no-checkout "$GIT_URL" "$WORK_DIR" || die "falha ao clonar o Quickshell"
fi

if ! git -C "$WORK_DIR" cat-file -e "${BASE_REV}^{commit}" 2>/dev/null; then
	log "rev-base ausente localmente; tentando fetch"
	git -C "$WORK_DIR" fetch --quiet origin "$BASE_REV" \
		|| die "rev-base $BASE_REV não disponível (sem rede?)"
fi

# Restaura a árvore no rev-base. "clean -fd" remove artefatos do patch sem
# apagar o diretório build/ ignorado, preservando o cache de compilação.
git -C "$WORK_DIR" checkout --force --detach "$BASE_REV"
git -C "$WORK_DIR" reset --hard --quiet "$BASE_REV"
git -C "$WORK_DIR" clean -fdq

# 2. Aplica o patch.
log "verificando o patch"
git -C "$WORK_DIR" apply --check "$PATCH" || die "patch não aplica limpo no rev-base"
git -C "$WORK_DIR" apply "$PATCH"

# 3. Configuração + build + instalação.
BUILD_DIR="$WORK_DIR/build"
mkdir -p "$PREFIX"

log "configurando CMake (RelWithDebInfo)"
cmake -B "$BUILD_DIR" -S "$WORK_DIR" "${GENERATOR[@]}" \
	-DCMAKE_BUILD_TYPE=RelWithDebInfo \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DINSTALL_QML_PREFIX=lib/qt6/qml \
	-DDISTRIBUTOR="local (webview patch)" \
	-DUSE_JEMALLOC=OFF \
	-DBUILD_TESTING=OFF \
	-DCRASH_REPORTER=OFF

log "compilando com $JOBS job(s)"
cmake --build "$BUILD_DIR" -j "$JOBS"

log "instalando em $PREFIX"
cmake --install "$BUILD_DIR"

log "concluído: $PREFIX/bin/quickshell"
log "use scripts/qs (ou o wrapper em ~/.local/bin/qs) para executar o binário patchado"
