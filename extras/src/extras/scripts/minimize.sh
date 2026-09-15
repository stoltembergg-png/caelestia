#!/usr/bin/env bash
# Portado de Serpantinum: src/scripts/minimize.sh (AGPL-3.0)
#
# Minimize windows to the "special:minimized" special workspace on Hyprland
# (macOS-style minimize-to-dock) and restore them on demand.
#
# Estado gravado em $XDG_STATE_HOME/caelestia/dock/minimized.json, o mesmo
# diretório de Caching.getStateDir("dock") (Paths.state + "/dock") usado pelo
# dock do caelestia-extras. Não depende de ambiente do Serpantinum.

set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/caelestia/dock"
STATE_FILE="$STATE_DIR/minimized.json"
SPECIAL_WS="special:minimized"

need_hyprland() {
    if ! command -v hyprctl >/dev/null 2>&1 || [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        echo "minimize: Hyprland indisponível (hyprctl/HYPRLAND_INSTANCE_SIGNATURE)" >&2
        exit 1
    fi
}

need_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "minimize: jq não encontrado" >&2
        exit 1
    fi
}

notify() {
    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send -a "Caelestia Extras" "$1" 2>/dev/null || true
}

# hypr_dispatch <dispatcher> <args> <lua-expression>
# Usa o dispatcher clássico (equivale a Hypr.dispatch/"hyprctl dispatch") e cai
# para o parser Lua (`hyprctl eval`) quando o clássico não está disponível.
hypr_dispatch() {
    if hyprctl dispatch "$1" "$2" >/dev/null 2>&1; then
        return 0
    fi
    hyprctl eval "$3" >/dev/null 2>&1
}

load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE" 2>/dev/null || echo "[]"
    else
        echo "[]"
    fi
}

save_state() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    printf '%s\n' "$1" >"$STATE_FILE"
}

# Drop entries whose windows no longer exist.
prune_state() {
    local state addrs
    state="$(load_state)"
    addrs="$(hyprctl clients -j 2>/dev/null | jq -r '.[].address' 2>/dev/null)"
    state="$(printf '%s' "$state" | jq --argjson keep "$(printf '%s' "$addrs" | jq -R . | jq -s .)" \
        'map(select(.address as $a | $keep | index($a)))' 2>/dev/null || echo "[]")"
    save_state "$state"
    printf '%s' "$state"
}

active_address() {
    hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty' 2>/dev/null
}

focused_workspace_id() {
    hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty' 2>/dev/null
}

cmd_minimize() {
    need_hyprland
    need_jq
    local addr="${1:-}"
    [[ -z "$addr" ]] && addr="$(active_address)"
    if [[ -z "$addr" ]]; then
        echo "minimize: nenhuma janela ativa" >&2
        exit 1
    fi
    local info cls title floating wsname
    info="$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address == $a) | "\(.class)\t\(.title)\t\(.floating)\t\(.workspace.name)"' 2>/dev/null | head -n 1)"
    IFS=$'\t' read -r cls title floating wsname <<<"$info"
    # Hyprland may report a hidden special-workspace window as active;
    # minimizing it again is a no-op that corrupts state - refuse instead.
    if [[ "$wsname" == special* ]]; then
        echo "minimize: janela já minimizada" >&2
        exit 0
    fi
    # Float first so the tiling layout doesn't reflow when the window leaves
    # (macOS-like behavior); original state is restored on unminimize.
    local was_floating="true"
    if [[ "$floating" != "true" ]]; then
        was_floating="false"
        hypr_dispatch setfloating "address:$addr" \
            "hl.dispatch(hl.dsp.window.float({ action = \"set\", window = \"address:$addr\" }))"
    fi
    hypr_dispatch movetoworkspacesilent "$SPECIAL_WS,address:$addr" \
        "hl.dispatch(hl.dsp.window.move({ workspace = \"$SPECIAL_WS\", window = \"address:$addr\" }))"
    local state
    state="$(prune_state)"
    state="$(printf '%s' "$state" | jq --arg a "$addr" --arg c "$cls" --arg t "$title" --argjson f "$was_floating" \
        'map(select(.address != $a)) + [{address: $a, class: $c, title: $t, floating: $f}]' 2>/dev/null)"
    save_state "$state"
    notify "Janela minimizada"
    echo "Janela minimizada"
}

cmd_restore() {
    need_hyprland
    need_jq
    local addr="${1:-}"
    if [[ -z "$addr" ]]; then
        echo "minimize: endereço da janela ausente" >&2
        exit 1
    fi
    local ws
    ws="$(focused_workspace_id)"
    [[ -z "$ws" ]] && ws="1"
    hypr_dispatch movetoworkspacesilent "$ws,address:$addr" \
        "hl.dispatch(hl.dsp.window.move({ workspace = $ws, window = \"address:$addr\" }))"
    hypr_dispatch focuswindow "address:$addr" \
        "hl.dispatch(hl.dsp.focus({ window = \"address:$addr\" }))"
    local state was_floating
    state="$(prune_state)"
    was_floating="$(printf '%s' "$state" | jq -r --arg a "$addr" '.[] | select(.address == $a) | .floating // true' 2>/dev/null | head -n 1)"
    if [[ "$was_floating" == "false" ]]; then
        # small delay: unsetting float in the same tick as leaving the
        # special workspace is silently dropped by the compositor
        sleep 0.5
        hypr_dispatch settiled "address:$addr" \
            "hl.dispatch(hl.dsp.window.float({ action = \"unset\", window = \"address:$addr\" }))"
    fi
    state="$(printf '%s' "$state" | jq --arg a "$addr" 'map(select(.address != $a))' 2>/dev/null || echo "[]")"
    save_state "$state"
    echo "Janela restaurada"
}

cmd_list() {
    need_hyprland
    need_jq
    prune_state | jq -r '.[] | "\(.address)|\(.class)|\(.title)"' 2>/dev/null
}

case "${1:-}" in
    ""|minimize) cmd_minimize "${2:-}" ;;
    0x*) cmd_minimize "$1" ;;
    restore) cmd_restore "${2:-}" ;;
    list) cmd_list ;;
    -h|--help|help)
        cat <<'EOF'
Uso: minimize.sh [minimize [ADDR] | restore ADDR | list | help]
  minimize [ADDR]  Minimiza a janela ativa (ou ADDR) para special:minimized
  restore ADDR     Restaura a janela ADDR para o workspace focado
  list             Lista as janelas minimizadas (ADDR|CLASS|TITLE)
EOF
        ;;
    *)
        echo "minimize: argumento desconhecido: $1" >&2
        exit 1
        ;;
esac
