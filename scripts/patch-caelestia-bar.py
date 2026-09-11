#!/usr/bin/env python3
"""Adiciona a entrada "kodexbar" na barra do Caelestia (fork local), de forma idempotente.

- modules/bar/Bar.qml: adiciona `import qs.extras.nolimits` + um DelegateChoice roleValue "kodexbar"
  que instancia NoLimitsBarItem (com backup do arquivo).
- ~/.config/caelestia/shell.json: adiciona a entrada {"id": "kodexbar", "enabled": true} em
  bar.entries, se o arquivo existir (melhor esforço; formatos dict e list são suportados).

Uso: python3 scripts/patch-caelestia-bar.py [CAELESTIA_DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import sys

MARK_BEGIN = "// >>> caelestia-extras bar"
MARK_END = "// <<< caelestia-extras bar"
IMPORT_LINE = "import qs.extras.nolimits"

INSERT = f"""{MARK_BEGIN}
            DelegateChoice {{
                roleValue: "kodexbar"
                delegate: EntryWrapper {{
                    NoLimitsBarItem {{
                        objectName: "taskbarKodexBar"
                    }}
                }}
            }}
            {MARK_END}
"""


def find_matching_brace(text: str, open_idx: int) -> int:
    depth = 0
    i = open_idx
    n = len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def patch_bar_qml(path: str, dry: bool) -> bool:
    text = open(path, encoding="utf-8").read()
    if MARK_BEGIN in text:
        print(f"Bar.qml: já patchado ({path})")
        return False
    if "NoLimitsBarItem" in text:
        print("Bar.qml: já contém NoLimitsBarItem (sem marcador; deixando como está)")
        return False

    m = re.search(r"DelegateChooser\s*\{", text)
    if not m:
        print("AVISO: DelegateChooser não encontrado em Bar.qml; patch da barra ignorado")
        return False
    close = find_matching_brace(text, m.end() - 1)
    if close < 0:
        print("AVISO: não consegui casar as chaves do DelegateChooser; patch ignorado")
        return False

    new_text = text[:close] + INSERT + text[close:]

    if IMPORT_LINE not in new_text:
        # insere após a última linha de import
        lines = new_text.split("\n")
        last = max(i for i, l in enumerate(lines) if l.strip().startswith("import "))
        lines.insert(last + 1, IMPORT_LINE)
        new_text = "\n".join(lines)

    if dry:
        print(f"Bar.qml: seria patchado ({len(new_text) - len(text)} bytes) — dry-run")
        return True

    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, f"{path}.bak-{stamp}")
    open(path, "w", encoding="utf-8").write(new_text)
    print(f"Bar.qml: patch aplicado (backup .bak-{stamp})")
    return True


def patch_shell_json(path: str, dry: bool) -> None:
    if not os.path.exists(path):
        print(f"shell.json: não existe ainda ({path}); adicione depois a entrada "
              '{"id": "kodexbar", "enabled": true} em bar.entries (ou use a UI de settings)')
        return
    try:
        data = json.load(open(path, encoding="utf-8"))
    except Exception as e:
        print(f"shell.json: não consegui ler ({e}); pulando")
        return

    bar = data.setdefault("bar", {})
    entries = bar.get("entries")
    changed = False
    if isinstance(entries, dict):
        if "kodexbar" not in entries:
            entries["kodexbar"] = {"enabled": True}
            changed = True
    elif isinstance(entries, list):
        if not any(isinstance(e, dict) and e.get("id") == "kodexbar" for e in entries):
            entries.append({"id": "kodexbar", "enabled": True})
            changed = True
    elif entries is None:
        bar["entries"] = {"kodexbar": {"enabled": True}}
        changed = True
    else:
        print("shell.json: formato de bar.entries não reconhecido; adicione manualmente")
        return

    if not changed:
        print("shell.json: entrada kodexbar já presente")
        return
    if dry:
        print("shell.json: seria atualizado — dry-run")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, f"{path}.bak-{stamp}")
    json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"shell.json: entrada kodexbar adicionada (backup .bak-{stamp})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("caelestia_dir", nargs="?", default=os.path.expanduser("~/.config/quickshell/caelestia"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    bar_qml = os.path.join(args.caelestia_dir, "modules", "bar", "Bar.qml")
    if not os.path.exists(bar_qml):
        print(f"ERRO: não encontrei {bar_qml}", file=sys.stderr)
        return 1
    patch_bar_qml(bar_qml, args.dry_run)
    patch_shell_json(os.path.expanduser("~/.config/caelestia/shell.json"), args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
