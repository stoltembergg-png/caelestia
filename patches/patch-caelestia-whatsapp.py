#!/usr/bin/env python3
"""Integra o Drawer nativo do WhatsApp (módulo `qs.extras.whatsapp`) ao core do
Caelestia, de forma idempotente.

Este script é a Fase 3 do `caelestia-whatsapp`: o módulo QML é copiado pelo
`scripts/install-shell.sh` para `$CAELESTIA_DIR/extras/whatsapp/` (com `qmldir`
próprio, `module qs.extras.whatsapp`); este patch liga o `Drawer` ao core
instalado. Ver `docs/INTEGRATION.md`.

Pontos do patch (contrato congelado em
`caelestia-extras/docs/PORT-SPEC-WHATSAPP-V2.md`, secção "Patch do core (L2)"):

1. modules/drawers/Panels.qml
     * `import qs.extras.whatsapp as ExtrasWhatsApp` (no topo, marcador);
     * `readonly property alias whatsapp: whatsapp` (junto aos demais aliases);
     * `ExtrasWhatsApp.Drawer { id: whatsapp; screen: root.screen;
       screenState: root.screenState; anchors.top/bottom/left: parent.* }`
       (marcador, antes do `Sidebar.Wrapper`).
2. modules/drawers/ContentWindow.qml
     * `PanelBg { id: whatsappBg; panel: panels.whatsapp; deformAmount: 0.03;
       implicitHeight: panel.height * (1 / rawDeformMatrix.m22) + 2 }`
       (marcador, junto aos demais PanelBg do blobGroup);
     * `whatsapp.transform: Matrix4x4 { matrix: whatsappBg.deformMatrix }`
       (marcador, DENTRO do bloco `Panels` — sem o prefixo `panels.`, que seria
       o mesmo tipo de erro já cometido no patch da dock);
     * `|| panels.whatsapp.visible` no binding de `WlrLayershell.keyboardFocus`
       (OnDemand só quando visível).
3. modules/drawers/Regions.qml
     * `R { panel: root.panels.whatsapp; y: 0;
       height: panel.height * (1 - panel.offsetScale) + root.borderThickness }`
       (marcador).
4. modules/drawers/Interactions.qml
     * sensor de borda à DIREITA da barra (faixa
       `x ∈ [bar.implicitWidth - 2, bar.implicitWidth + waEdgeW]`) + dwell de
       450 ms para abrir e timer de 300 ms para fechar, com supressão quando
       `popouts.hasCurrent || pressed` (e `fullscreen`);
     * fecha em `onContainsMouseChanged` (ao perder o rato) e em
       `onFullscreenChanged`.
     Adaptado aos nomes/estrutura reais do ficheiro (o spec referia
     `root.lastX/lastY`; o core usa `root.mouseX/mouseY`).

Todas as edições usam marcadores `// >>> caelestia-extras whatsapp` /
`// <<< caelestia-extras whatsapp` e são idempotentes (verificadas pelo
conteúdo inserido). Cada ficheiro alterado ganha backup `.bak-*`. `--dry-run`
reporta sem alterar nada.

Uso:
    python3 patches/patch-caelestia-whatsapp.py [CAELESTIA_DIR] [--dry-run]

`CAELESTIA_DIR` é o diretório do core Caelestia (default:
`~/.config/quickshell/caelestia`); o módulo QML deve ter sido previamente
copiado para `CAELESTIA_DIR/extras/whatsapp/` (feito por `install-shell.sh`).
"""
from __future__ import annotations

import argparse
import datetime
import os
import re
import shutil
import sys

MARK_BEGIN = "// >>> caelestia-extras whatsapp"
MARK_END = "// <<< caelestia-extras whatsapp"

IMPORT_WHATSAPP = "import qs.extras.whatsapp as ExtrasWhatsApp"


# --------------------------------------------------------------------------- #
# Helpers (mesma base do patch-caelestia-dock.py)
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
    if text[end:end + 1] == "\n":
        end += 1
    return text[:cb + 1] + "\n" + block.rstrip("\n") + "\n" + text[end:], True


def replace_once(text: str, old: str, new: str) -> tuple[str, bool]:
    """Substitui `old` por `new` uma única vez; no-op se `old` ausente."""
    if old not in text:
        return text, False
    return text.replace(old, new, 1), True


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
    "    readonly property alias whatsapp: whatsapp",
    indent="    ",
)

PANELS_DRAWER = wrap(
    """\
    ExtrasWhatsApp.Drawer {
        id: whatsapp
        screen: root.screen
        screenState: root.screenState

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
    }""",
    indent="    ",
)


def patch_panels(path: str, dry: bool) -> bool:
    original = read(path)
    text = original
    changed = False

    # 1a. Import namespaced do módulo do WhatsApp.
    text, imp = ensure_import_block(text, IMPORT_WHATSAPP)
    changed = changed or imp

    # 1b. Alias `whatsapp` (junto aos demais aliases). Âncora estável: alias sidebar.
    if not re.search(r"readonly\s+property\s+alias\s+whatsapp\s*:", text):
        text, ok = insert_after_line(text, r"readonly\s+property\s+alias\s+sidebar\s*:", PANELS_ALIAS)
        if ok:
            changed = True
        else:
            print("AVISO: alias 'sidebar' não encontrado em Panels.qml; alias 'whatsapp' ignorado")

    # 1c. Instância do painel nativa antes do Sidebar.Wrapper.
    if "ExtrasWhatsApp.Drawer" not in text:
        text, ok = insert_before_line(text, r"Sidebar\.Wrapper\s*\{", PANELS_DRAWER)
        if ok:
            changed = True
        else:
            print("AVISO: âncora 'Sidebar.Wrapper {' não encontrada em Panels.qml; drawer do WhatsApp ignorado")

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
WHATSAPP_BG = wrap(
    """\
        PanelBg {
            id: whatsappBg
            panel: panels.whatsapp
            deformAmount: 0.03
            implicitHeight: panel.height * (1 / rawDeformMatrix.m22) + 2
        }""",
    indent="        ",
)

WHATSAPP_TRANSFORM = wrap(
    """\
            whatsapp.transform: Matrix4x4 {
                matrix: whatsappBg.deformMatrix
            }""",
    indent="            ",
)

FOCUS_OLD = "screenState.launcher || screenState.session ?"
FOCUS_NEW = "screenState.launcher || screenState.session || panels.whatsapp.visible ?"


def patch_content_window(path: str, dry: bool) -> bool:
    original = read(path)
    text = original
    changed = False

    # 2a. PanelBg do WhatsApp, junto aos demais (após o sidebarBg).
    if "id: whatsappBg" not in text:
        text, ok = insert_after_enclosing_block(text, r"id\s*:\s*sidebarBg\b", WHATSAPP_BG)
        if ok:
            changed = True
        else:
            print("AVISO: bloco 'sidebarBg' não encontrado em ContentWindow.qml; PanelBg do WhatsApp ignorado")

    # 2b. Wiring do transform DENTRO do bloco `Panels` (sem prefixo `panels.`).
    if "whatsapp.transform" not in text:
        text, ok = insert_after_enclosing_block(text, r"matrix\s*:\s*sidebarBg\.deformMatrix", WHATSAPP_TRANSFORM)
        if ok:
            changed = True
        else:
            print("AVISO: transform da sidebar não encontrado em ContentWindow.qml; transform do WhatsApp ignorado")

    # 2c. keyboardFocus OnDemand quando o drawer está visível.
    if "panels.whatsapp.visible" not in text:
        text, ok = replace_once(text, FOCUS_OLD, FOCUS_NEW)
        if ok:
            changed = True
        else:
            print("AVISO: binding de keyboardFocus não encontrado em ContentWindow.qml; foco do WhatsApp ignorado")

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
WHATSAPP_REGION = wrap(
    """\
    R {
        panel: root.panels.whatsapp
        y: 0
        height: panel.height * (1 - panel.offsetScale) + root.borderThickness
    }""",
    indent="    ",
)


def patch_regions(path: str, dry: bool) -> bool:
    original = read(path)
    text = original

    if "panel: root.panels.whatsapp" in text:
        print("Regions.qml: já patchado, nada a fazer")
        return False

    text, ok = insert_after_enclosing_block(text, r"panel\s*:\s*root\.panels\.dashboard", WHATSAPP_REGION)
    if not ok:
        print("AVISO: região do dashboard não encontrada em Regions.qml; região do WhatsApp ignorada")
        return False
    if dry:
        print(f"Regions.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Regions.qml", dry)
    return True


# --------------------------------------------------------------------------- #
# 4. Interactions.qml
# --------------------------------------------------------------------------- #
WA_PROPS = wrap(
    """\
    readonly property real waEdgeW: Math.max(4, Tokens.padding.small)
    property bool waEdgeHovered: false

    Timer {
        id: waDwell

        interval: 450
        repeat: false
        onTriggered: if (root.waEdgeHovered)
            root.panels.whatsapp.open()
    }

    Timer {
        id: waHide

        interval: 300
        repeat: false
        onTriggered: if (!root.inLeftPanel(root.panels.whatsapp, root.mouseX, root.mouseY) && !root.waEdgeHovered)
            root.panels.whatsapp.close()
    }""",
    indent="    ",
)

WA_FULLSCREEN = wrap(
    """\
    onFullscreenChanged: {
        if (fullscreen) {
            waDwell.stop();
            waHide.stop();
            root.panels.whatsapp.close();
        }
    }""",
    indent="    ",
)

WA_SENSOR = wrap(
    """\
        const onEdge = x >= bar.implicitWidth - 2 && x <= bar.implicitWidth + waEdgeW;
        const inWa = inLeftPanel(panels.whatsapp, x, y);
        waEdgeHovered = onEdge && !pressed && !popouts.hasCurrent && !fullscreen;
        if (waEdgeHovered)
            waDwell.restart();
        else
            waDwell.stop();
        if (inWa || onEdge)
            waHide.stop();
        else if (panels.whatsapp.visible)
            waHide.restart();""",
    indent="        ",
)

WA_CONTAINS = wrap(
    """\
            waHide.stop();
            waDwell.stop();
            root.panels.whatsapp.close();""",
    indent="            ",
)


def patch_interactions(path: str, dry: bool) -> bool:
    original = read(path)
    text = original

    # Idempotência por conteúdo: o sensor define `waEdgeW`. Aplicamos tudo de
    # uma vez e escrevemos uma única vez, pelo que não há estados parciais.
    if "waEdgeW" in text:
        print("Interactions.qml: já patchado, nada a fazer")
        return False

    changed = False

    # 4a. Propriedades + timers (após os flags de shortcut).
    text, ok = insert_after_line(text, r"property\s+bool\s+utilitiesShortcutActive", WA_PROPS)
    if ok:
        changed = True
    else:
        print("AVISO: 'utilitiesShortcutActive' não encontrado em Interactions.qml; props/timers do WhatsApp ignorados")

    # 4b. Fechar em fullscreen.
    text, ok = insert_after_line(text, r"hoverEnabled\s*:\s*true", WA_FULLSCREEN)
    if ok:
        changed = True
    else:
        print("AVISO: 'hoverEnabled: true' não encontrado em Interactions.qml; fullscreen do WhatsApp ignorado")

    # 4c. Sensor de borda dentro de onPositionChanged (após x/y).
    text, ok = insert_after_line(text, r"const\s+y\s*=\s*event\.y;", WA_SENSOR)
    if ok:
        changed = True
    else:
        print("AVISO: 'const y = event.y;' não encontrado em Interactions.qml; sensor do WhatsApp ignorado")

    # 4d. Fechar ao perder o rato.
    text, ok = insert_after_line(text, r"if\s*\(!containsMouse\)\s*\{", WA_CONTAINS)
    if ok:
        changed = True
    else:
        print("AVISO: bloco 'if (!containsMouse)' não encontrado em Interactions.qml; fecho do WhatsApp ignorado")

    if not changed:
        print("Interactions.qml: já patchado, nada a fazer")
        return False
    if dry:
        print(f"Interactions.qml: seria atualizado ({len(text) - len(original)} bytes) — dry-run")
        return True
    write_with_backup(path, text, "Interactions.qml", dry)
    return True


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="Patch idempotente do core para o drawer nativo do WhatsApp do Caelestia.")
    ap.add_argument("caelestia_dir", nargs="?", default=os.path.expanduser("~/.config/quickshell/caelestia"),
                    help="diretório do core (default: ~/.config/quickshell/caelestia)")
    ap.add_argument("--dry-run", action="store_true", help="reporta sem alterar ficheiros")
    args = ap.parse_args()

    base = os.path.abspath(os.path.expanduser(args.caelestia_dir))
    drawers = os.path.join(base, "modules", "drawers")
    module_dir = os.path.join(base, "extras", "whatsapp")

    print(f"core: {base}{' (dry-run)' if args.dry_run else ''}")

    if not os.path.isdir(drawers):
        print(f"ERRO: não encontrei os drawers do core: {drawers}", file=sys.stderr)
        print("      confirme o CAELESTIA_DIR ou instale o Caelestia.", file=sys.stderr)
        return 1

    # Pré-requisito do patch: o módulo `qs.extras.whatsapp` tem de existir.
    qmldir = os.path.join(module_dir, "qmldir")
    if not os.path.isfile(qmldir):
        print(f"AVISO: não encontrei {qmldir}", file=sys.stderr)
        print("       o patch referencia `qs.extras.whatsapp`; rode antes o install-shell.sh", file=sys.stderr)

    targets = [
        (os.path.join(drawers, "Panels.qml"), patch_panels),
        (os.path.join(drawers, "ContentWindow.qml"), patch_content_window),
        (os.path.join(drawers, "Regions.qml"), patch_regions),
        (os.path.join(drawers, "Interactions.qml"), patch_interactions),
    ]

    # Validação de âncoras/estrutura: os 4 ficheiros do core são obrigatórios.
    missing = [path for path, _ in targets if not os.path.isfile(path)]
    if missing:
        print("ERRO: ficheiros do core não encontrados:", file=sys.stderr)
        for path in missing:
            print(f"      - {path}", file=sys.stderr)
        return 2

    changed = 0
    for path, fn in targets:
        if fn(path, args.dry_run):
            changed += 1

    if changed == 0:
        print("resultado: já patchado — nada a fazer (idempotente)")
    elif args.dry_run:
        print(f"resultado: {changed} ficheiro(s) seriam atualizados (dry-run)")
    else:
        print(f"resultado: {changed} ficheiro(s) atualizados")
    return 0


if __name__ == "__main__":
    sys.exit(main())
