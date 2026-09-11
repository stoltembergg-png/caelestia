#!/usr/bin/env python3
"""Integra o No Limits (KodexBar) ao core do Caelestia (fork local), de forma idempotente.

- modules/bar/Bar.qml:
    * `import qs.extras.nolimits` + `import qs.extras as Extras` (namespaced, para
      não colidir com o `Config` do core);
    * um DelegateChoice roleValue "kodexbar" que instancia NoLimitsBarItem com
      `bar: root` (permite ao item abrir o popout nativo);
    * um bloco `openNoLimits()` + `Connections` que reagem a `Extras.NoLimits.showRequested`
      e abrem o popout nativo "nolimits".
- modules/bar/popouts/Content.qml:
    * `import qs.extras.nolimits` + um Popout "nolimits" hospedando NoLimitsPopout.
- modules/bar/popouts/Wrapper.qml:
    * estende o `when` do Binding de keyboardFocus para incluir o popout "nolimits"
      (Esc/foco).
- ~/.config/caelestia/shell.json: adiciona a entrada {"id": "kodexbar", "enabled": true} em
  bar.entries, se o arquivo existir (melhor esforço; formatos dict e list são suportados).

Todas as edições usam marcadores `// >>> caelestia-extras ...` / `// <<< caelestia-extras ...`
(ou substituição exata) e são idempotentes. Cada arquivo alterado ganha backup `.bak-*`.

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
NL_BEGIN = "// >>> caelestia-extras nolimits"
NL_END = "// <<< caelestia-extras nolimits"
IMPORT_NL = "import qs.extras.nolimits"
IMPORT_EXTRAS = "import qs.extras as Extras"

INSERT = f"""{MARK_BEGIN}
            DelegateChoice {{
                roleValue: "kodexbar"
                delegate: EntryWrapper {{
                    NoLimitsBarItem {{
                        bar: root
                        objectName: "taskbarKodexBar"
                    }}
                }}
            }}
            {MARK_END}
"""

# Inserido antes de `spacing: Tokens.spacing.medium`, dentro do ColumnLayout root.
BAR_NL_INSERT = f"""    {NL_BEGIN}
    function openNoLimits(): void {{
        let entry = null;
        for (let i = 0; i < repeater.count; i++) {{
            const e = repeater.itemAt(i) as EntryWrapper;
            if (e?.entryId === "kodexbar") {{ entry = e; break; }}
        }}
        if (!entry) return;
        popouts.currentName = "nolimits";
        popouts.currentCenter = Qt.binding(() => (entry.item as Item).mapToItem(root, 0, (entry.item as Item).implicitHeight / 2).y);
        popouts.hasCurrent = true;
    }}

    Connections {{
        target: Extras.NoLimits
        function onShowRequested(view) {{
            if (Hypr.focusedMonitor?.name !== screen.name) return;
            root.openNoLimits();
        }}
    }}
    {NL_END}

"""

# Inserido imediatamente antes do Repeater dos tray menus (após o Popout lockstatus).
CONTENT_INSERT = f"""        {NL_BEGIN}
        Popout {{
            name: "nolimits"
            sourceComponent: NoLimitsPopout {{
                popouts: root.popouts
            }}
        }}
        {NL_END}

"""

WRAPPER_OLD_WHEN = 'when: root.isDetached || (root.hasCurrent && root.currentName === "wirelesspassword")'
WRAPPER_NEW_WHEN = ('when: root.isDetached || (root.hasCurrent && (root.currentName === "wirelesspassword" '
                    '|| root.currentName === "nolimits"))')


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


def ensure_import(text: str, import_line: str) -> tuple[str, bool]:
    """Insere `import_line` após a última linha de import, se ainda não existir."""
    if re.search(r"^[ \t]*" + re.escape(import_line) + r"[ \t]*$", text, re.M):
        return text, False
    lines = text.split("\n")
    idxs = [i for i, l in enumerate(lines) if l.strip().startswith("import ")]
    if not idxs:
        return text, False
    lines.insert(max(idxs) + 1, import_line)
    return "\n".join(lines), True


def insert_before_line(text: str, anchor: str, block: str) -> tuple[str, bool]:
    """Insere `block` imediatamente antes da linha que contém `anchor`."""
    idx = text.find(anchor)
    if idx < 0:
        return text, False
    line_start = text.rfind("\n", 0, idx) + 1
    return text[:line_start] + block + text[line_start:], True


def write_with_backup(path: str, new_text: str, label: str, dry: bool) -> None:
    if dry:
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, f"{path}.bak-{stamp}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print(f"{label}: patch aplicado (backup .bak-{stamp})")


def patch_bar_qml(path: str, dry: bool) -> bool:
    with open(path, encoding="utf-8") as f:
        original = f.read()
    text = original
    changed = False

    # 1. DelegateChoice roleValue "kodexbar" (com bar: root).
    if MARK_BEGIN not in text:
        if "NoLimitsBarItem" in text:
            print("Bar.qml: já contém NoLimitsBarItem (sem marcador; deixando como está)")
        else:
            m = re.search(r"DelegateChooser\s*\{", text)
            if not m:
                print("AVISO: DelegateChooser não encontrado em Bar.qml; patch da barra ignorado")
            else:
                close = find_matching_brace(text, m.end() - 1)
                if close < 0:
                    print("AVISO: não consegui casar as chaves do DelegateChooser; patch ignorado")
                else:
                    text = text[:close] + INSERT + text[close:]
                    changed = True
    # 1b. Garante `bar: root` no NoLimitsBarItem (cobre patch antigo sem o binding).
    #     O check é escopado ao corpo do NoLimitsBarItem, pois `bar: root` já
    #     aparece em outros delegates (ex.: ActiveWindow).
    mm = re.search(r"^([ \t]*)NoLimitsBarItem\s*\{", text, re.M)
    if not mm:
        print("AVISO: NoLimitsBarItem não encontrado em Bar.qml; `bar: root` ignorado")
    else:
        close = find_matching_brace(text, mm.end() - 1)
        inner = text[mm.end():close] if close >= 0 else ""
        if not re.search(r"\bbar\s*:", inner):
            indent = mm.group(1)
            text = text[:mm.end()] + f"\n{indent}    bar: root" + text[mm.end():]
            changed = True

    # 2. Imports (namespaced + submodule).
    text, imp1 = ensure_import(text, IMPORT_NL)
    text, imp2 = ensure_import(text, IMPORT_EXTRAS)
    changed = changed or imp1 or imp2

    # 3. Bloco openNoLimits() + Connections.
    if NL_BEGIN not in text:
        text, ok = insert_before_line(text, "spacing: Tokens.spacing.medium", BAR_NL_INSERT)
        if ok:
            changed = True
        else:
            print("AVISO: âncora 'spacing: Tokens.spacing.medium' não encontrada em Bar.qml; "
                  "bloco nolimits ignorado")

    if not changed:
        print("Bar.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"Bar.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Bar.qml", dry)
    return True


def patch_content_qml(path: str, dry: bool) -> bool:
    if not os.path.exists(path):
        print(f"AVISO: não encontrei {path}; popout nativo do nolimits ignorado")
        return False
    with open(path, encoding="utf-8") as f:
        original = f.read()
    text = original
    changed = False

    text, imp = ensure_import(text, IMPORT_NL)
    changed = changed or imp

    if NL_BEGIN not in text:
        text, ok = insert_before_line(text, "        Repeater {", CONTENT_INSERT)
        if ok:
            changed = True
        else:
            print("AVISO: âncora 'Repeater {' não encontrada em Content.qml; "
                  "popout nolimits ignorado")

    if not changed:
        print("Content.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"Content.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Content.qml", dry)
    return True


def patch_wrapper_qml(path: str, dry: bool) -> bool:
    if not os.path.exists(path):
        print(f"AVISO: não encontrei {path}; foco/Esc do popout nolimits ignorado")
        return False
    with open(path, encoding="utf-8") as f:
        original = f.read()

    if WRAPPER_NEW_WHEN in original:
        print("Wrapper.qml: já patchado, nada a fazer")
        return False
    if WRAPPER_OLD_WHEN not in original:
        print("AVISO: linha 'when:' do keyboardFocus não encontrada em Wrapper.qml; patch ignorado")
        return False

    text = original.replace(WRAPPER_OLD_WHEN, WRAPPER_NEW_WHEN, 1)
    if dry:
        print(f"Wrapper.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Wrapper.qml", dry)
    return True


def patch_shell_json(path: str, dry: bool) -> None:
    if not os.path.exists(path):
        print(f"shell.json: não existe ainda ({path}); adicione depois a entrada "
              '{"id": "kodexbar", "enabled": true} em bar.entries (ou use a UI de settings)')
        return
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
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
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"shell.json: entrada kodexbar adicionada (backup .bak-{stamp})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("caelestia_dir", nargs="?", default=os.path.expanduser("~/.config/quickshell/caelestia"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    bar_qml = os.path.join(args.caelestia_dir, "modules", "bar", "Bar.qml")
    content_qml = os.path.join(args.caelestia_dir, "modules", "bar", "popouts", "Content.qml")
    wrapper_qml = os.path.join(args.caelestia_dir, "modules", "bar", "popouts", "Wrapper.qml")

    if not os.path.exists(bar_qml):
        print(f"ERRO: não encontrei {bar_qml}", file=sys.stderr)
        return 1

    patch_bar_qml(bar_qml, args.dry_run)
    patch_content_qml(content_qml, args.dry_run)
    patch_wrapper_qml(wrapper_qml, args.dry_run)
    patch_shell_json(os.path.expanduser("~/.config/caelestia/shell.json"), args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
