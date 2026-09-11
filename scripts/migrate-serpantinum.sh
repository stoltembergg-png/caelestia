#!/usr/bin/env bash
# Migra dados do Serpantinum para o Caelestia (melhor esforço, idempotente).
# - estado do No Limits: ~/.local/state/serpantinum/nolimits -> ~/.local/state/caelestia/nolimits
# - bloco "noLimits" de ~/.config/serpantinum/settings.json -> ~/.config/caelestia/extras.json
set -euo pipefail

SRC_STATE="$HOME/.local/state/serpantinum/nolimits"
DST_STATE="$HOME/.local/state/caelestia/nolimits"

if [ -d "$SRC_STATE" ] && [ ! -e "$DST_STATE" ]; then
  mkdir -p "$(dirname "$DST_STATE")"
  cp -a "$SRC_STATE" "$DST_STATE"
  echo "migrado estado NoLimits: $SRC_STATE -> $DST_STATE"
else
  echo "estado NoLimits: nada a migrar (origem ausente ou destino já existe)"
fi

python3 - <<'PY'
import json, os

src = os.path.expanduser("~/.config/serpantinum/settings.json")
dst = os.path.expanduser("~/.config/caelestia/extras.json")
if not os.path.exists(dst):
    print("settings: extras.json ainda não existe (criado na 1ª execução do Caelestia); rode de novo depois")
elif not os.path.exists(src):
    print("settings: settings.json do Serpantinum não existe; nada a migrar")
else:
    try:
        s = json.load(open(src, encoding="utf-8"))
        d = json.load(open(dst, encoding="utf-8"))
        if "noLimits" in s and "noLimits" not in d:
            d["noLimits"] = s["noLimits"]
            json.dump(d, open(dst, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
            print("settings: bloco noLimits migrado para extras.json")
        else:
            print("settings: nada a migrar (já existe no destino ou ausente na origem)")
    except Exception as e:
        print("settings: aviso — migração falhou:", e)
PY
