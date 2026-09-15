// Portado de Serpantinum / Caelestia (AGPL-3.0)
// Estado compartilhado da dock nativa (L1).
//
// Registro: singleton no qmldir RAIZ do módulo (src/extras/qmldir):
//   singleton DockState 1.0 dock/DockState.qml
// O patch do core consome via `import qs.extras as Extras`:
//   * modules/drawers/Exclusions.qml -> exclusiveZone: Extras.DockState.reservedSpace
// O DockWrapper escreve reservedSpace/fullscreenActive/visible conforme o estado real.

pragma Singleton

import QtQuick
import Quickshell

Singleton {
    id: root

    // Altura reservada no rodapé (px). Só > 0 quando a dock está fixa
    // (exclusive && !autohide), visível e sem fullscreen ativo.
    property real reservedSpace: 0

    // Espelho do fullscreen do toplevel ativo lido pelo wrapper no serviço Hypr.
    property bool fullscreenActive: false

    // Visibilidade lógica da dock (observável por outros consumidores).
    property bool visible: false
}
