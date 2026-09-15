#!/usr/bin/env python3
"""Integra o badge do WhatsApp (módulo `qs.extras.whatsapp`) à barra do core do
Caelestia, de forma idempotente.

Complementa `patch-caelestia-whatsapp.py` (Fase 3, drawers): aqui adiciona-se o
item de barra que abre/mostra o estado do WhatsApp.

Pontos do patch:

1. `modules/bar/Bar.qml`
     * `import qs.extras.whatsapp` + `import qs.extras.whatsapp as ExtrasWhatsApp`
       (marcador, após a última linha de import);
     * um `DelegateChoice { roleValue: "whatsapp"; delegate: EntryWrapper {
       WhatsAppBarItem { bar: root; objectName: "taskbarWhatsApp" } } }`
       inserido no fim do `DelegateChooser` (mesmo padrão do `kodexbar`).
2. `~/.config/caelestia/shell.json` (melhor esforço; formatos dict e list)
     * entrada `{"id": "whatsapp", "enabled": true}` em `bar.entries`, se o ficheiro
       existir. O caminho default é derivado de `CAELESTIA_DIR` (o pai-de-dois-níveis
       do core é `~/.config`, logo `~/.config/caelestia/shell.json`); pode ser
       sobreposto com `--shell-json PATH`.

Todas as edições usam marcadores `// >>> caelestia-extras whatsapp-bar` /
`// <<< caelestia-extras whatsapp-bar` e são idempotentes (uma segunda execução é
no-op). Cada ficheiro alterado ganha backup `.bak-*`. `--dry-run` reporta sem
alterar nada.

Uso:
    python3 patches/patch-caelestia-whatsapp-bar.py [CAELESTIA_DIR] [--dry-run] [--shell-json PATH]

`CAELESTIA_DIR` é o diretório do core Caelestia (default:
`~/.config/quickshell/caelestia`); o módulo QML deve ter sido previamente
copiado para `CAELESTIA_DIR/extras/whatsapp/` (feito por `install-shell.sh`).
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import sys

MARK_BEGIN = "// >>> caelestia-extras whatsapp-bar"
MARK_END = "// <<< caelestia-extras whatsapp-bar"

# Import namespaced (evita colisões com tipos do core) + sem namespace (para
# referenciar `WhatsAppBarItem` diretamente, como no snippet do contrato).
IMPORT_PLAIN = "import qs.extras.whatsapp"
IMPORT_NS = "import qs.extras.whatsapp as ExtrasWhatsApp"

BAR_ID = "whatsapp"


# --------------------------------------------------------------------------- #
# Helpers (mesma base dos outros patches do repositório)
# --------------------------------------------------------------------------- #
def find_matching_brace(text: str, open_idx: int) -> int:
    """Devolve o índice do `}` que casa com o `{` em `open_idx` (ignora strings/comentários)."""
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


def ensure_import_block(text: str, import_lines: list[str]) -> tuple[str, bool]:
    """Insere `import_lines` (com marcadores) após a última linha de import, se ausentes."""
    if all(re.search(r"^[ \t]*" + re.escape(l) + r"[ \t]*$", text, re.M) for l in import_lines):
        return text, False
    lines = text.split("\n")
    idxs = [i for i, l in enumerate(lines) if l.strip().startswith("import ")]
    if not idxs:
        return text, False
    insert_at = max(idxs) + 1
    # Sai para fora de marcadores de fecho imediatamente a seguir, para não aninhar.
    while insert_at < len(lines) and re.match(r"\s*//\s*<<<", lines[insert_at]):
        insert_at += 1
    block = [MARK_BEGIN, *import_lines, MARK_END]
    lines[insert_at:insert_at] = block
    return "\n".join(lines), True


def write_with_backup(path: str, new_text: str, label: str, dry: bool) -> None:
    if dry:
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, f"{path}.bak-{stamp}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print(f"{label}: patch aplicado (backup .bak-{stamp})")


def read(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return f.read()


# --------------------------------------------------------------------------- #
# 1. modules/bar/Bar.qml
# --------------------------------------------------------------------------- #
def build_delegate_block(indent: str) -> str:
    i = indent
    inner = i + "    "
    return (
        f"{i}{MARK_BEGIN}\n"
        f"{i}DelegateChoice {{\n"
        f'{inner}roleValue: "whatsapp"\n'
        f"{inner}delegate: EntryWrapper {{\n"
        f"{inner}    WhatsAppBarItem {{\n"
        f"{inner}        bar: root\n"
        f'{inner}        objectName: "taskbarWhatsApp"\n'
        f"{inner}    }}\n"
        f"{inner}}}\n"
        f"{i}}}\n"
        f"{i}{MARK_END}\n"
    )


def patch_bar_qml(path: str, dry: bool) -> bool:
    original = read(path)
    text = original
    changed = False

    # 1a. Imports.
    text, imp = ensure_import_block(text, [IMPORT_PLAIN, IMPORT_NS])
    changed = changed or imp

    # 1b. DelegateChoice "whatsapp" no fim do DelegateChooser.
    if "WhatsAppBarItem" not in text:
        m = re.search(r"DelegateChooser\s*\{", text)
        if not m:
            print("AVISO: DelegateChooser não encontrado em Bar.qml; badge do WhatsApp ignorado")
        else:
            close = find_matching_brace(text, m.end() - 1)
            if close < 0:
                print("AVISO: não consegui casar as chaves do DelegateChooser; badge do WhatsApp ignorado")
            else:
                line_start = text.rfind("\n", 0, close) + 1
                indent = text[line_start:close]
                if not indent.strip():
                    indent = "            "  # 12 espaços, alinhado aos DelegateChoice
                text = text[:line_start] + build_delegate_block(indent) + text[line_start:]
                changed = True

    if not changed:
        print("Bar.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"Bar.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Bar.qml", dry)
    return True


# --------------------------------------------------------------------------- #
# 2. ~/.config/caelestia/shell.json
# --------------------------------------------------------------------------- #
def default_shell_json(base: str) -> str:
    """Deriva `~/.config/caelestia/shell.json` a partir de `CAELESTIA_DIR`.

    Para o default `~/.config/quickshell/caelestia` devolve exatamente
    `~/.config/caelestia/shell.json`. Para um diretório de teste fora do
    `~/.config`, devolve um caminho que provavelmente não existe (o patch então
    apenas avisa, sem tocar em nada).
    """
    config_root = os.path.dirname(os.path.dirname(base))
    return os.path.join(config_root, "caelestia", "shell.json")


def patch_shell_json(path: str, dry: bool) -> None:
    if not os.path.exists(path):
        print(f"shell.json: não existe ainda ({path}); adicione depois a entrada "
              '{"id": "whatsapp", "enabled": true} em bar.entries (ou use a UI de settings)')
        return
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:  # noqa: BLE001
        print(f"shell.json: não consegui ler ({e}); pulando")
        return

    bar = data.setdefault("bar", {})
    entries = bar.get("entries")
    changed = False
    if isinstance(entries, dict):
        if BAR_ID not in entries:
            entries[BAR_ID] = {"enabled": True}
            changed = True
    elif isinstance(entries, list):
        if not any(isinstance(e, dict) and e.get("id") == BAR_ID for e in entries):
            entries.append({"id": BAR_ID, "enabled": True})
            changed = True
    elif entries is None:
        bar["entries"] = {BAR_ID: {"enabled": True}}
        changed = True
    else:
        print("shell.json: formato de bar.entries não reconhecido; adicione manualmente")
        return

    if not changed:
        print("shell.json: entrada whatsapp já presente")
        return
    if dry:
        print("shell.json: seria atualizado — dry-run")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, f"{path}.bak-{stamp}")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"shell.json: entrada whatsapp adicionada (backup .bak-{stamp})")


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(
        description="Patch idempotente da barra do core para o badge nativo do WhatsApp do Caelestia."
    )
    ap.add_argument("caelestia_dir", nargs="?", default=os.path.expanduser("~/.config/quickshell/caelestia"),
                    help="diretório do core (default: ~/.config/quickshell/caelestia)")
    ap.add_argument("--dry-run", action="store_true", help="reporta sem alterar ficheiros")
    ap.add_argument("--shell-json", default=None,
                    help="caminho do shell.json (default: derivado de CAELESTIA_DIR)")
    args = ap.parse_args()

    base = os.path.abspath(os.path.expanduser(args.caelestia_dir))
    bar_qml = os.path.join(base, "modules", "bar", "Bar.qml")

    print(f"core: {base}{' (dry-run)' if args.dry_run else ''}")

    if not os.path.isfile(bar_qml):
        print(f"ERRO: não encontrei {bar_qml}", file=sys.stderr)
        print("      confirme o CAELESTIA_DIR ou instale o Caelestia.", file=sys.stderr)
        return 1

    module_dir = os.path.join(base, "extras", "whatsapp")
    qmldir = os.path.join(module_dir, "qmldir")
    if not os.path.isfile(qmldir):
        print(f"AVISO: não encontrei {qmldir}", file=sys.stderr)
        print("       o patch referencia `qs.extras.whatsapp`; rode antes o install-shell.sh", file=sys.stderr)

    changed = 0
    if patch_bar_qml(bar_qml, args.dry_run):
        changed += 1

    shell_json = args.shell_json or default_shell_json(base)
    patch_shell_json(os.path.expanduser(shell_json), args.dry_run)

    if changed == 0:
        print("resultado: já patchado — nada a fazer (idempotente)")
    elif args.dry_run:
        print(f"resultado: {changed} ficheiro(s) seriam atualizados (dry-run)")
    else:
        print(f"resultado: {changed} ficheiro(s) atualizados")
    return 0


if __name__ == "__main__":
    sys.exit(main())
