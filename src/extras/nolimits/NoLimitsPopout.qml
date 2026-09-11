// Integração do No Limits ao sistema NATIVO de popouts da barra do Caelestia
// (lado extras). Conteúdo hospedado pelo popout "nolimits": o host nativo
// (Content/Wrapper) instancia este Item passando `popouts`. A visibilidade real
// do painel continua dirigida pelo singleton NoLimits (atalho/IPC), e as duas
// sincronizações abaixo acoplam o singleton ao estado do popout nativo:
//  - popout fechou (hasCurrent/currentName mudou) -> esconde o singleton;
//  - singleton sumiu (atalho/IPC) -> fecha o popout nativo de forma idempotente.
//
// Assim os atalhos/IPC que chamam NoLimits.toggle()/show() abrem o popout, e o
// clique fora/close nativo esconde o singleton.

import QtQuick
import Quickshell
import Caelestia.Config
import qs.extras

Item {
    id: root

    required property var popouts

    // Teto pela tela (o Content.qml ainda soma Tokens.padding.large de cada lado).
    readonly property real maxHeight: Math.min(560, (QsWindow.window?.height ?? 1000) - Tokens.padding.extraLarge * 2)

    implicitWidth: Tokens.sizes.utilities.width
    // Segue a altura natural da aba ativa do popup (popup.implicitHeight), com
    // mínimo sensato para loading/abas curtas — sem sobrar blob vazio embaixo.
    implicitHeight: Math.min(root.maxHeight, Math.max(220, popup.implicitHeight))

    NoLimitsPopup {
        id: popup
        anchors.fill: parent
    }

    // Popout nativo fechou -> o singleton some (cobre clique fora / close()).
    Connections {
        target: root.popouts

        function onHasCurrentChanged() {
            if (!root.popouts.hasCurrent)
                NoLimits.hide();
        }

        function onCurrentNameChanged() {
            if (root.popouts.currentName !== "nolimits")
                NoLimits.hide();
        }
    }

    // Singleton sumiu (atalho/IPC) -> o popout nativo fecha.
    Connections {
        target: NoLimits

        function onVisibleChanged() {
            if (!NoLimits.visible && root.popouts && root.popouts.hasCurrent && root.popouts.currentName === "nolimits")
                root.popouts.hasCurrent = false;
        }
    }
}
