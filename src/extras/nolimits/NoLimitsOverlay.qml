// Portado de Serpantinum: src/quickshell/kodexbar/KodexBarPopup.qml + bar/modules/KodexBarWidget.qml (AGPL-3.0)
// Host novo (não existe equivalente 1:1 no Serpantinum): um StyledWindow por tela
// hospeda o NoLimitsPopup. O estado vem do singleton NoLimits (lane N1): o overlay
// lê NoLimits.visible e escuta NoLimits.showRequested. Sem âncora de barra e sem
// IPC externo/script do Serpantinum.
//
// Decisões de layout (adaptação do popup 400x480 top-right do Serpantinum):
//  - largura = Tokens.sizes.utilities.width (default 430), altura = 520;
//  - ancorado no canto superior direito "perto da barra": topMargin =
//    Tokens.sizes.bar.innerWidth + Tokens.padding.medium (~52, equivalente ao
//    mt:52 do WindowRegistry original), rightMargin = Tokens.padding.extraSmall;
//  - backdrop transparente full-screen fecha ao clique; Esc também fecha;
//  - só a tela focada interage (Hypr.focusedMonitor.name === screen.name).

import QtQuick
import QtQuick.Layouts
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

                // Topo do painel: espelha o antigo offset de 52px do popup do
                // Serpantinum (barra ~40 + folga média).
                readonly property real panelTop: Tokens.sizes.bar.innerWidth + Tokens.padding.medium
                readonly property real panelRight: Tokens.padding.extraSmall

                // Backdrop transparente: clique fora do painel fecha o overlay.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    onClicked: NoLimits.hide()
                }

                Item {
                    id: panel

                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.topMargin: win.panelTop
                    anchors.rightMargin: win.panelRight

                    width: Math.min(Tokens.sizes.utilities.width, win.width - Tokens.padding.medium * 2)
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
