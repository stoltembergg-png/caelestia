#!/usr/bin/env bash
# check-i18n.sh — valida a integridade da internacionalização do workspace.
#
# Verifica:
#   1. Paridade de chaves-FOLHA entre os idiomas de cada diretório de idiomas
#      (serpantinum: en == pt == es; extras: en == pt).
#   2. Ausência de valores vazios ou somente com espaços/tabs.
#   3. Paridade dos placeholders entre idiomas, por chave-FOLHA.
#   4. Ausência de chaves JSON duplicadas quando python3 está disponível.
#   5. Resolução de toda chave usada via I18n.t("...") / Extras.I18n.t("...")
#      em en.json E pt.json do diretório de idiomas que o consumidor carrega.
#   6. Ausência de qsTr(...) nos consumidores (não há arquivos .ts no repo,
#      então qsTr não traduz nada — deve ser I18n.t()).
#
# Uso:  extras/scripts/check-i18n.sh        (a partir de qualquer diretório)
# Sai com 0 se tudo OK; 1 se houver qualquer falha.
#
# Dependências: bash, jq, grep.
#
# Allowlist de chaves dinâmicas: chaves montadas por concatenação em runtime
# (ex.: "whatsapp.chat_list.weekdays." + dia) não podem ser verificadas
# estaticamente; seus prefixos ficam listados em DYNAMIC_PREFIX.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
    printf 'FAIL: dependência ausente: jq\n' >&2
    exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$REPO_ROOT" || exit 2

fail=0
note() { printf '%s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

if command -v python3 >/dev/null 2>&1; then
    HAVE_PYTHON3=1
else
    HAVE_PYTHON3=0
    note "SKIP duplicatas (python3 ausente)"
fi

# consumidor-de-QML : diretório-de-idiomas-carregado
CONSUMERS=(
    "custom/serpantinum/src/quickshell:custom/serpantinum/src/assets/languages"
    "extras/src/extras:extras/src/extras/assets/languages"
    "whatsapp/shell:extras/src/extras/assets/languages"
)

DYNAMIC_PREFIX=("whatsapp.chat_list.weekdays.")

is_dynamic() {
    local k="$1" p
    for p in "${DYNAMIC_PREFIX[@]}"; do
        if [[ "$k" == "$p" && "$k" == *. ]]; then
            return 0
        fi
    done
    return 1
}

leaves() { jq -r 'paths(scalars) | join(".")' "$1" | sort; }

placeholder_map() {
    local file="$1" key value placeholders placeholder
    while IFS=$'\t' read -r key value; do
        [ -z "$key" ] && continue
        placeholders="$(printf '%s' "$value" | grep -oE '\{[a-zA-Z0-9_]+\}' || true)"
        while IFS= read -r placeholder; do
            [ -z "$placeholder" ] || printf '%s\t%s\n' "$key" "$placeholder"
        done <<< "$placeholders"
    done < <(jq -r 'paths(scalars) as $p | [($p | join(".")), getpath($p)] | @tsv' "$file")
}

check_duplicate_json() {
    local file="$1"
    python3 - "$file" <<'PY'
import json
import sys

class DuplicateKey(ValueError):
    pass

def strict_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKey(key)
        result[key] = value
    return result

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        json.load(stream, object_pairs_hook=strict_object)
except DuplicateKey as error:
    print(f"duplicate key {error.args[0]!r}", file=sys.stderr)
    sys.exit(1)
PY
}

check_languages_dir() {
    local dir="$1"
    shift
    local langs=("$@")
    local base="${langs[0]}" l errors=0

    [ -d "$dir" ] || { bad "diretório de idiomas inexistente: $dir"; return; }

    for l in "${langs[@]}"; do
        if ! jq empty "$dir/$l.json" 2>/dev/null; then
            bad "JSON inválido ou ausente: $dir/$l.json"
            return
        fi
        if [ "$HAVE_PYTHON3" = "1" ] && ! check_duplicate_json "$dir/$l.json"; then
            bad "chaves JSON duplicadas: $dir/$l.json"
            errors=1
        fi
    done

    for l in "${langs[@]:1}"; do
        local d
        d="$(diff <(leaves "$dir/$base.json") <(leaves "$dir/$l.json"))"
        if [ -n "$d" ]; then
            bad "paridade de chaves $base/$l divergente em $dir"
            printf '%s\n' "$d" | sed 's/^/      /' >&2
            errors=1
        fi
    done

    for l in "${langs[@]:1}"; do
        local placeholders
        placeholders="$(diff <(placeholder_map "$dir/$base.json" | sort -u) <(placeholder_map "$dir/$l.json" | sort -u))"
        if [ -n "$placeholders" ]; then
            bad "placeholders divergentes em $dir ($base/$l)"
            printf '%s\n' "$placeholders" | sed 's/^/      /' >&2
            errors=1
        fi
    done

    for l in "${langs[@]}"; do
        local n
        n="$(jq -r '[paths(scalars) as $p | select(getpath($p) == "")] | length' "$dir/$l.json")"
        if [ "$n" != "0" ]; then
            bad "$dir/$l.json tem $n valor(es) de string vazio(s)"
            errors=1
        fi

        local whitespace_keys
        whitespace_keys="$(jq -r 'paths(scalars) as $p | getpath($p) as $v | select(($v | type) == "string") | select($v | test("^[ \\t]+$")) | ($p | join("."))' "$dir/$l.json")"
        if [ -n "$whitespace_keys" ]; then
            bad "$dir/$l.json tem valor(es) somente com espaços/tabs"
            printf '%s\n' "$whitespace_keys" | sed 's/^/      /' >&2
            errors=1
        fi
    done

    [ "$errors" = "0" ] && note "OK  paridade ${langs[*]} :: $dir"
}

check_consumer() {
    local consumer="$1" langdir="$2" k f resolved miss=0

    [ -d "$consumer" ] || { bad "consumidor inexistente: $consumer"; return; }
    [ -d "$langdir" ]  || { bad "diretório de idiomas inexistente: $langdir"; return; }

    local keys
    keys="$(grep -rhoE '\.t\([[:space:]]*"[a-z0-9_.]+"' "$consumer" --include='*.qml' 2>/dev/null \
        | sed -E 's/.*"([a-z0-9_.]+)"/\1/' | sort -u)"

    while IFS= read -r k; do
        [ -z "$k" ] && continue
        if is_dynamic "$k"; then
            note "SKIP chave dinâmica: $k"
            continue
        fi
        for f in "$langdir/en.json" "$langdir/pt.json"; do
            if ! jq -e --arg k "$k" \
                'reduce ($k|split("."))[] as $p (.; if . == null then null else .[$p] end) | type == "string"' \
                "$f" >/dev/null 2>&1; then
                bad "chave não resolvida em $(basename "$f"): $k (usada em $consumer)"
                miss=$((miss + 1))
            fi
        done
    done <<< "$keys"

    local n_keys
    n_keys="$(printf '%s\n' "$keys" | grep -c . || true)"
    [ "$miss" = "0" ] && note "OK  $n_keys chave(s) I18n.t() resolvem :: $consumer"

    local qs
    qs="$(grep -rl 'qsTr(' "$consumer" --include='*.qml' 2>/dev/null || true)"
    if [ -n "$qs" ]; then
        bad "qsTr() encontrado (sem .ts no repo, não traduz): $(printf '%s' "$qs" | tr '\n' ' ')"
    fi
}

note "== check-i18n :: $REPO_ROOT"
check_languages_dir "custom/serpantinum/src/assets/languages" en pt es
check_languages_dir "extras/src/extras/assets/languages" en pt

for pair in "${CONSUMERS[@]}"; do
    check_consumer "${pair%%:*}" "${pair##*:}"
done

if [ "$fail" = "0" ]; then
    note "== i18n OK"
else
    note "== i18n FALHOU" >&2
fi
exit "$fail"
