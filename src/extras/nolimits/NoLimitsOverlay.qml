// Portado de Serpantinum: src/quickshell/kodexbar/KodexBarPopup.qml + bar/modules/KodexBarWidget.qml (AGPL-3.0)
// Host novo (não existe equivalente 1:1 no Serpantinum): um StyledWindow por tela
// hospeda o NoLimitsPopup. O estado vem do singleton NoLimits (lane N1): o overlay
// lê NoLimits.visible e escuta NoLimits.showRequested. Sem âncora de barra e sem
// IPC externo/script do Serpantinum.
//
// Decisões de layout (adaptação do popup 400x480 top-right do Serpantinum para a
// barra VERTICAL À ESQUERDA):
//  - o popup abre AO LADO da barra esquerda: leftMargin = largura interna da barra
//    + folga grande (Tokens.sizes.bar.innerWidth + Tokens.padding.large * 2), com o
//    topo perto do topo da barra (Tokens.padding.large);
//  - largura = Tokens.sizes.utilities.width (default 430), altura limitada a 520;
//  - backdrop transparente full-screen fecha ao clique; Esc também fecha;
//  - só a tela focada interage (Hypr.focusedMonitor.name === screen.name).

import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import qs.services
import qs.components.containers
import qs.extras

Scope {
    id: root

    Variants {
        model: Screens.screens

        delegate: Component {
            StyledWindow {
                id: win

                required property ShellScreen modelData

                screen: modelData
                name: "extras-nolimits"

                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.exclusionMode: ExclusionMode.Ignore
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand

                anchors {
                    top: true
                    bottom: true
                    left: true
                    right: true
                }

                color: "transparent"

                // Só a tela com foco interage.
                readonly property bool focused: {
                    const mon = Hypr.focusedMonitor;
                    return !mon || mon.name === win.screen.name;
                }

                visible: NoLimits.visible && win.focused

                // Ao lado da barra esquerda: barra ~40px interna + folga generosa.
                readonly property real panelLeft: Tokens.sizes.bar.innerWidth + Tokens.padding.large * 2
                // Topo do painel alinhado ao primeiro item da barra.
                readonly property real panelTop: Tokens.padding.large

                // Backdrop transparente: clique fora do painel fecha o overlay.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onClicked: NoLimits.hide()
                }

                Item {
                    id: panel

                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.topMargin: win.panelTop
                    anchors.leftMargin: win.panelLeft

                    width: Math.min(Tokens.sizes.utilities.width, win.width - win.panelLeft - Tokens.padding.medium)
                    height: Math.min(520, win.height - win.panelTop - Tokens.padding.medium)

                    // Engole cliques que não foram tratados pelo conteúdo do popup
                    // (o fundo do popup é transparente a eventos) para o backdrop
                    // não fechar ao clicar dentro do painel.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.AllButtons
                    }

                    NoLimitsPopup {
                        id: popup

                        anchors.fill: parent
                        visible: NoLimits.visible
                    }
                }

                Shortcut {
                    sequence: "Escape"
                    enabled: win.visible
                    onActivated: NoLimits.hide()
                }

                // O estado é dirigido pelo singleton. `show()` já grava
                // requestedView antes de emitir; aqui apenas reforçamos a troca de
                // aba e pedimos foco de teclado na tela alvo.
                Connections {
                    target: NoLimits

                    function onShowRequested(view) {
                        if (!win.focused)
                            return;
                        popup.gotoTab(view);
                        Qt.callLater(() => popup.forceActiveFocus());
                    }
                }
            }
        }
    }
}
