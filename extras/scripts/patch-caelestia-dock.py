#!/usr/bin/env python3
"""Integra a Dock nativa (L1) ao core do Caelestia (fork local), de forma idempotente.

Pontos do patch (contrato congelado em docs/PORT-SPEC-DOCK.md, secção "Patch do
core (L2)"):

1. modules/drawers/Panels.qml
     * `import qs.extras.dock as ExtrasDock` (no topo, marcador);
     * `readonly property alias dock: dock` (junto aos demais aliases);
     * `ExtrasDock.Wrapper { id: dock; screen: root.screen;
       screenState: root.screenState; anchors.horizontalCenter: parent.horizontalCenter;
       anchors.bottom: parent.bottom }` (marcador).
2. modules/drawers/ContentWindow.qml
     * `PanelBg { id: dockBg; panel: panels.dock; deformAmount: 0.1 }` (marcador,
       junto aos demais PanelBg do blobGroup);
     * `dock.transform: Matrix4x4 { matrix: dockBg.deformMatrix }` (marcador,
       junto ao bloco de wiring dos painéis).
3. modules/drawers/Regions.qml
     * `R { panel: root.panels.dock; y: root.win.height - height;
       height: Math.max(panel.height * (1 - panel.offsetScale), panel.sensorHeight)
       + root.borderThickness }` (marcador).
4. modules/drawers/Exclusions.qml
     * `import qs.extras as Extras` (alias! o core também tem `Config` atachado)
       e bloco `StyledWindow { screen: root.screen; name: "border-exclusion";
       anchors.bottom: true; exclusiveZone: Extras.DockState.reservedSpace;
       mask: Region {}; implicitWidth: 1; implicitHeight: 1 }` (marcador).

Todas as edições usam marcadores `// >>> caelestia-extras dock` /
`// <<< caelestia-extras dock` e são idempotentes (a idempotência é verificada
pelo conteúdo inserido, pelo que marcadores repetidos no mesmo ficheiro são
seguros). Cada ficheiro alterado ganha backup `.bak-*`. `--dry-run` reporta sem
alterar nada.

Uso: python3 scripts/patch-caelestia-dock.py [CAELESTIA_DIR] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import shutil
import sys

MARK_BEGIN = "// >>> caelestia-extras dock"
MARK_END = "// <<< caelestia-extras dock"

IMPORT_DOCK = "import qs.extras.dock as ExtrasDock"
IMPORT_EXTRAS = "import qs.extras as Extras"


# --------------------------------------------------------------------------- #
# Helpers
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


def _find(text: str, pattern: str) -> int:
    """Procura `pattern` (regex) e devolve o índice do início, ou -1."""
    m = re.search(pattern, text)
    return m.start() if m else -1


def find_enclosing_block(text: str, pattern: str) -> tuple[int, int] | None:
    """Localiza o bloco `{...}` mais interno que contém `pattern` (regex).

    Devolve (indice_da_chave_aberta, indice_da_chave_fechada) ou None.
    """
    i = _find(text, pattern)
    if i < 0:
        return None
    ob = text.rfind("{", 0, i)
    while ob >= 0:
        cb = find_matching_brace(text, ob)
        if cb >= i:
            return ob, cb
        ob = text.rfind("{", 0, ob)
    return None


def wrap(block: str, indent: str = "") -> str:
    """Envolve `block` (já indentado) com os marcadores, terminando em newline."""
    return f"{indent}{MARK_BEGIN}\n{block}\n{indent}{MARK_END}\n"


def ensure_import_block(text: str, import_line: str) -> tuple[str, bool]:
    """Insere `import_line` (com marcadores) após a última linha de import, se ausente."""
    if re.search(r"^[ \t]*" + re.escape(import_line) + r"[ \t]*$", text, re.M):
        return text, False
    lines = text.split("\n")
    idxs = [i for i, l in enumerate(lines) if l.strip().startswith("import ")]
    if not idxs:
        return text, False
    insert_at = max(idxs) + 1
    lines[insert_at:insert_at] = [MARK_BEGIN, import_line, MARK_END]
    return "\n".join(lines), True


def insert_before_line(text: str, pattern: str, block: str) -> tuple[str, bool]:
    """Insere `block` imediatamente antes da linha que contém `pattern` (regex)."""
    idx = _find(text, pattern)
    if idx < 0:
        return text, False
    line_start = text.rfind("\n", 0, idx) + 1
    return text[:line_start] + block + text[line_start:], True


def insert_after_line(text: str, pattern: str, block: str) -> tuple[str, bool]:
    """Insere `block` imediatamente após a linha que contém `pattern` (regex)."""
    idx = _find(text, pattern)
    if idx < 0:
        return text, False
    eol = text.find("\n", idx)
    if eol < 0:
        return text + "\n" + block.rstrip("\n"), True
    return text[: eol + 1] + block + text[eol + 1:], True


def insert_after_enclosing_block(text: str, pattern: str, block: str) -> tuple[str, bool]:
    """Insere `block` imediatamente após o bloco `{...}` mais interno que contém `pattern` (regex)."""
    span = find_enclosing_block(text, pattern)
    if span is None:
        return text, False
    _, cb = span
    end = cb + 1
    # Consome a newline que fecha a linha do `}` para não deixar linhas em branco extra.
    if text[end:end + 1] == "\n":
        end += 1
    return text[:cb + 1] + "\n" + block.rstrip("\n") + "\n" + text[end:], True


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
# 1. Panels.qml
# --------------------------------------------------------------------------- #
PANELS_ALIAS = wrap(
    "    readonly property alias dock: dock",
    indent="    ",
)

PANELS_WRAPPER = wrap(
    """\
    ExtrasDock.Wrapper {
        id: dock
        screen: root.screen
        screenState: root.screenState

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
    }""",
    indent="    ",
)


def patch_panels(path: str, dry: bool) -> bool:
    original = read(path)
    text = original
    changed = False

    # 1a. Import namespaced do módulo da dock.
    text, imp = ensure_import_block(text, IMPORT_DOCK)
    changed = changed or imp

    # 1b. Alias `dock` (junto aos demais aliases). Âncora estável: alias sidebar.
    if not re.search(r"readonly\s+property\s+alias\s+dock\s*:", text):
        text, ok = insert_after_line(text, r"readonly\s+property\s+alias\s+sidebar\s*:", PANELS_ALIAS)
        if ok:
            changed = True
        else:
            print("AVISO: alias 'sidebar' não encontrado em Panels.qml; alias 'dock' ignorado")

    # 1c. Instância do painel nativa no fim dos wrappers.
    if "ExtrasDock.Wrapper" not in text:
        text, ok = insert_before_line(text, r"Sidebar\.Wrapper\s*\{", PANELS_WRAPPER)
        if ok:
            changed = True
        else:
            print("AVISO: âncora 'Sidebar.Wrapper {' não encontrada em Panels.qml; wrapper da dock ignorado")

    if not changed:
        print("Panels.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"Panels.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Panels.qml", dry)
    return True


# --------------------------------------------------------------------------- #
# 2. ContentWindow.qml
# --------------------------------------------------------------------------- #
DOCK_BG = wrap(
    """\
        PanelBg {
            id: dockBg
            panel: panels.dock
            deformAmount: 0.1
        }""",
    indent="        ",
)

DOCK_TRANSFORM = wrap(
    """\
            dock.transform: Matrix4x4 {
                matrix: dockBg.deformMatrix
            }""",
    indent="            ",
)


def patch_content_window(path: str, dry: bool) -> bool:
    original = read(path)
    text = original
    changed = False

    # 2a. PanelBg da dock, junto aos demais (após o popoutBg).
    if "id: dockBg" not in text:
        text, ok = insert_after_enclosing_block(text, r"id\s*:\s*popoutBg\b", DOCK_BG)
        if ok:
            changed = True
        else:
            print("AVISO: bloco 'popoutBg' não encontrado em ContentWindow.qml; PanelBg da dock ignorado")

    # 2b. Wiring do transform, junto aos demais (após o transform dos popouts).
    if "dock.transform" not in text:
        text, ok = insert_after_enclosing_block(text, r"matrix\s*:\s*popoutBg\.deformMatrix", DOCK_TRANSFORM)
        if ok:
            changed = True
        else:
            print("AVISO: transform dos popouts não encontrado em ContentWindow.qml; transform da dock ignorado")

    if not changed:
        print("ContentWindow.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"ContentWindow.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "ContentWindow.qml", dry)
    return True


# --------------------------------------------------------------------------- #
# 3. Regions.qml
# --------------------------------------------------------------------------- #
DOCK_REGION = wrap(
    """\
    R {
        panel: root.panels.dock
        y: root.win.height - height
        height: Math.max(panel.height * (1 - panel.offsetScale), panel.sensorHeight) + root.borderThickness
    }""",
    indent="    ",
)


def patch_regions(path: str, dry: bool) -> bool:
    original = read(path)
    text = original

    if "panel: root.panels.dock" in text:
        print("Regions.qml: já patchado, nada a fazer")
        return False

    text, ok = insert_after_enclosing_block(text, r"panel\s*:\s*root\.panels\.launcher", DOCK_REGION)
    if not ok:
        print("AVISO: região do launcher não encontrada em Regions.qml; região da dock ignorada")
        return False
    if dry:
        print(f"Regions.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Regions.qml", dry)
    return True


# --------------------------------------------------------------------------- #
# 4. Exclusions.qml
# --------------------------------------------------------------------------- #
DOCK_EXCLUSION = wrap(
    """\
    StyledWindow {
        screen: root.screen
        name: "border-exclusion"
        anchors.bottom: true
        exclusiveZone: Extras.DockState.reservedSpace
        mask: Region {}
        implicitWidth: 1
        implicitHeight: 1
    }""",
    indent="    ",
)


def patch_exclusions(path: str, dry: bool) -> bool:
    original = read(path)
    text = original
    changed = False

    # 4a. Import alias — o core já tem `Config` atachado, então usamos `as Extras`.
    text, imp = ensure_import_block(text, IMPORT_EXTRAS)
    changed = changed or imp

    # 4b. Zona de exclusão inferior ligada ao espaço reservado da dock.
    if "Extras.DockState.reservedSpace" not in text:
        text, ok = insert_before_line(text, r"component\s+ExclusionZone\s*:\s*StyledWindow\s*\{", DOCK_EXCLUSION)
        if ok:
            changed = True
        else:
            print("AVISO: âncora 'component ExclusionZone' não encontrada em Exclusions.qml; zona da dock ignorada")

    if not changed:
        print("Exclusions.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"Exclusions.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Exclusions.qml", dry)
    return True


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="Patch idempotente do core para a dock nativa do Caelestia.")
    ap.add_argument("caelestia_dir", nargs="?", default=os.path.expanduser("~/.config/quickshell/caelestia"),
                    help="diretório do core (default: ~/.config/quickshell/caelestia)")
    ap.add_argument("--dry-run", action="store_true", help="reporta sem alterar ficheiros")
    args = ap.parse_args()

    base = os.path.abspath(os.path.expanduser(args.caelestia_dir))
    drawers = os.path.join(base, "modules", "drawers")

    targets = [
        (os.path.join(drawers, "Panels.qml"), patch_panels),
        (os.path.join(drawers, "ContentWindow.qml"), patch_content_window),
        (os.path.join(drawers, "Regions.qml"), patch_regions),
        (os.path.join(drawers, "Exclusions.qml"), patch_exclusions),
    ]

    if not os.path.isdir(drawers):
        print(f"ERRO: não encontrei {drawers}", file=sys.stderr)
        return 1

    for path, fn in targets:
        if not os.path.exists(path):
            print(f"AVISO: não encontrei {path}; ignorado")
            continue
        fn(path, args.dry_run)

    return 0


if __name__ == "__main__":
    sys.exit(main())
