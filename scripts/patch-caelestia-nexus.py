#!/usr/bin/env python3
"""Integra as páginas "Dock" e "WhatsApp" aos Ajustes (Nexus) do core do Caelestia (fork local), de forma idempotente.

- modules/nexus/PageRegistry.qml:
    * `import qs.extras.settings as ExtrasSettings` (namespaced, para não colidir);
    * inserção, NO FIM da lista `pages`, das entradas:
      { label: qsTr("Dock"), icon: "dock", description: qsTr("Comportamento, aparência e animações da dock"), category: "shell" } e
      { label: qsTr("WhatsApp"), icon: "chat", description: qsTr("Comportamento, minimalismo e aparência"), category: "shell" }.
- modules/nexus/PageCompRegistry.qml:
    * o mesmo import;
    * inserção, NO FIM da lista `pageComps`, de:
      Component { StackPage { Component { ExtrasSettings.DockPage {} } } } e
      Component { StackPage { Component { ExtrasSettings.WhatsAppPage {} } } }.
- As duas listas (páginas × componentes) devem terminar com o MESMO tamanho; o
  script compara as contagens e aborta com aviso se divergirem.
- Inserir sempre no fim evita deslocar os índices existentes (o fork já tem
  páginas custom).

Cada bloco usa os marcadores `// >>> caelestia-extras <nome>-settings` /
`// <<< caelestia-extras <nome>-settings` (Dock e WhatsApp) e é idempotente
(a 2ª execução é no-op). Cada arquivo alterado ganha backup `.bak-*`.

Uso: python3 scripts/patch-caelestia-nexus.py [CAELESTIA_DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import shutil
import sys

IMPORT_LINE = "import qs.extras.settings as ExtrasSettings"

# Marcadores por bloco (a importação é compartilhada e fica sob o marcador da Dock).
DOCK_MARK_BEGIN = "// >>> caelestia-extras dock-settings"
DOCK_MARK_END = "// <<< caelestia-extras dock-settings"

# Entradas da PageRegistry (indentação RELATIVA; insert_entry prefixa o recuo da lista).
PAGE_ENTRY_DOCK = (
    "{\n"
    '    label: qsTr("Dock"),\n'
    '    icon: "dock",\n'
    '    description: qsTr("Comportamento, aparência e animações da dock"),\n'
    '    category: "shell"\n'
    "}"
)

PAGE_ENTRY_WA = (
    "{\n"
    '    label: qsTr("WhatsApp"),\n'
    '    icon: "chat",\n'
    '    description: qsTr("Comportamento, minimalismo e aparência"),\n'
    '    category: "shell"\n'
    "}"
)

# Entradas da PageCompRegistry (indentação RELATIVA).
COMP_ENTRY_DOCK = (
    "Component {\n"
    "    StackPage {\n"
    "        Component {\n"
    "            ExtrasSettings.DockPage {}\n"
    "        }\n"
    "    }\n"
    "}"
)

COMP_ENTRY_WA = (
    "Component {\n"
    "    StackPage {\n"
    "        Component {\n"
    "            ExtrasSettings.WhatsAppPage {}\n"
    "        }\n"
    "    }\n"
    "}"
)

PAGE_SENTINEL_DOCK = 'label: qsTr("Dock")'
PAGE_SENTINEL_WA = 'label: qsTr("WhatsApp")'
COMP_SENTINEL_DOCK = "ExtrasSettings.DockPage"
COMP_SENTINEL_WA = "ExtrasSettings.WhatsAppPage"

# Blocos na ORDEM de inserção (Dock antes de WhatsApp, ambos no fim da lista):
# (entrada, sentinela, marcador-início, marcador-fim).
PAGE_BLOCKS = [
    (PAGE_ENTRY_DOCK, PAGE_SENTINEL_DOCK, DOCK_MARK_BEGIN, DOCK_MARK_END),
]
COMP_BLOCKS = [
    (COMP_ENTRY_DOCK, COMP_SENTINEL_DOCK, DOCK_MARK_BEGIN, DOCK_MARK_END),
]

PAGES_RE = r"readonly\s+property\s+list<[^>]+>\s+pages\s*:\s*\["
COMPS_RE = r"readonly\s+property\s+list<[^>]+>\s+pageComps\s*:\s*\["
IMPORT_RE = r"^[ \t]*" + re.escape(IMPORT_LINE) + r"[ \t]*$"


def find_matching(text: str, open_idx: int, open_ch: str, close_ch: str) -> int:
    """Índice do fechamento que casa com `open_idx`, ignorando strings e comentários."""
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
        elif c == open_ch:
            depth += 1
        elif c == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def count_top_level_objects(body: str) -> int:
    """Conta objetos `{ ... }` de primeiro nível dentro de um corpo de lista."""
    depth = 0
    count = 0
    i = 0
    n = len(body)
    quote = None
    while i < n:
        c = body[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "\"'":
            quote = c
        elif c == "/" and i + 1 < n and body[i + 1] == "/":
            j = body.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == "/" and i + 1 < n and body[i + 1] == "*":
            j = body.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c == "{":
            if depth == 0:
                count += 1
            depth += 1
        elif c == "}":
            if depth > 0:
                depth -= 1
        i += 1
    return count


def list_body(text: str, prop_re: str):
    """Retorna (body_start, body_end) do corpo da lista declarada por `prop_re` ou (None, None)."""
    m = re.search(prop_re, text)
    if not m:
        return None, None
    open_idx = text.find("[", m.end() - 1)
    if open_idx < 0:
        return None, None
    close_idx = find_matching(text, open_idx, "[", "]")
    if close_idx < 0:
        return None, None
    return open_idx + 1, close_idx


def count_list(text: str, prop_re: str) -> int | None:
    start, end = list_body(text, prop_re)
    if start is None:
        return None
    return count_top_level_objects(text[start:end])


def last_significant_index(text: str) -> int:
    """Índice do último caractere não-branco/não-comentário de `text` (-1 se vazio)."""
    i = 0
    n = len(text)
    last = -1
    quote = None
    while i < n:
        c = text[i]
        if quote is not None:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
            else:
                last = i
        elif c in "\"'":
            quote = c
            last = i
        elif c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif not c.isspace():
            last = i
        i += 1
    return last


def add_marked_import(text: str) -> tuple[str, bool, bool]:
    """Adiciona o import marcado após o último import. Retorna (texto, mudou, encontrou_imports)."""
    if re.search(IMPORT_RE, text, re.M):
        return text, False, True
    lines = text.split("\n")
    idxs = [i for i, l in enumerate(lines) if l.strip().startswith("import ")]
    if not idxs:
        return text, False, False
    ins = max(idxs) + 1
    lines[ins:ins] = ["", DOCK_MARK_BEGIN, IMPORT_LINE, DOCK_MARK_END]
    return "\n".join(lines), True, True


def insert_entry(text: str, prop_re: str, entry: str, mark_begin: str, mark_end: str) -> tuple[str, bool]:
    """Insere a entrada marcada antes do `]` que fecha a lista de `prop_re`."""
    _, end = list_body(text, prop_re)
    if end is None:
        return text, False
    line_start = text.rfind("\n", 0, end) + 1
    indent = text[line_start:end]

    # O último item da lista pode não ter vírgula final (ex.: PageCompRegistry);
    # sem a vírgula, anexar um novo item gera erro de sintaxe. Garante o separador.
    last = last_significant_index(text[:line_start])
    if last >= 0 and text[last] != ",":
        text = text[:last + 1] + "," + text[last + 1:]
        end += 1
        line_start += 1
    block_lines = [indent + mark_begin]
    block_lines += [indent + ln for ln in entry.split("\n")]
    block_lines.append(indent + mark_end)
    block = "\n".join(block_lines) + "\n"
    return text[:line_start] + block + text[line_start:], True


def build_registry(text: str, prop_re: str, blocks, label: str) -> tuple[str, bool, int | None]:
    changed = False

    text, imp_changed, found_imports = add_marked_import(text)
    if imp_changed:
        changed = True
    elif not found_imports:
        print(f"AVISO: nenhum 'import' encontrado em {label}; import do extras ignorado")

    for entry, sentinel, mark_begin, mark_end in blocks:
        if sentinel in text:
            continue
        text, ok = insert_entry(text, prop_re, entry, mark_begin, mark_end)
        if ok:
            changed = True
        else:
            print(f"AVISO: lista alvo não encontrada em {label}; entrada ignorada")

    return text, changed, count_list(text, prop_re)


def write_with_backup(path: str, new_text: str, label: str, dry: bool) -> None:
    if dry:
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
    shutil.copy2(path, f"{path}.bak-{stamp}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_text)
    print(f"{label}: patch aplicado (backup .bak-{stamp})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("caelestia_dir", nargs="?", default=os.path.expanduser("~/.config/quickshell/caelestia"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    page_reg = os.path.join(args.caelestia_dir, "modules", "nexus", "PageRegistry.qml")
    page_comp = os.path.join(args.caelestia_dir, "modules", "nexus", "PageCompRegistry.qml")

    for path in (page_reg, page_comp):
        if not os.path.exists(path):
            print(f"ERRO: não encontrei {path}", file=sys.stderr)
            return 1

    with open(page_reg, encoding="utf-8") as f:
        pr_original = f.read()
    with open(page_comp, encoding="utf-8") as f:
        pc_original = f.read()

    pr_text, pr_changed, pr_count = build_registry(pr_original, PAGES_RE, PAGE_BLOCKS, "PageRegistry.qml")
    pc_text, pc_changed, pc_count = build_registry(pc_original, COMPS_RE, COMP_BLOCKS, "PageCompRegistry.qml")

    print(f"PageRegistry.qml: {pr_count} páginas | PageCompRegistry.qml: {pc_count} componentes")
    if pr_count is None or pc_count is None:
        print("AVISO: não consegui contar as duas listas; abortando sem escrever", file=sys.stderr)
        return 1
    if pr_count != pc_count:
        print(
            f"AVISO: listas divergem ({pr_count} páginas vs {pc_count} componentes); "
            "abortando sem escrever (insira as entradas no mesmo ponto)",
            file=sys.stderr,
        )
        return 1

    if not (pr_changed or pc_changed):
        print("Nexus: já patchado, nada a fazer")
        return 0

    if args.dry_run:
        if pr_changed:
            print(f"PageRegistry.qml: seria atualizado ({len(pr_text) - len(pr_original)} bytes) — dry-run")
        if pc_changed:
            print(f"PageCompRegistry.qml: seria atualizado ({len(pc_text) - len(pc_original)} bytes) — dry-run")
        return 0

    if pr_changed:
        write_with_backup(page_reg, pr_text, "PageRegistry.qml", args.dry_run)
    if pc_changed:
        write_with_backup(page_comp, pc_text, "PageCompRegistry.qml", args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
