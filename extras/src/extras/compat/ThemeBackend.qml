// Portado de Serpantinum: src/quickshell/singletons/theme/ThemeBackend.qml (AGPL-3.0)
// Shim para a API real do Caelestia: cores de conteúdo -> Colours.palette.*,
// superfícies -> Colours.tPalette.*, radii -> Tokens.rounding.*,
// fontFamily -> Tokens.font.body.medium.family. Não há matugen/font-scan no port:
// o tema real é fornecido pelo core (Colours/Tokens).

pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
import qs.services

Item {
    id: root

    // Tipografia (Serpantinum: fontFamily configurável)
    readonly property string fontFamily: Tokens.font.body.medium.family

    // Raios (Serpantinum default 8 -> Tokens.rounding.small = 8)
    readonly property int borderRadius: Tokens.rounding.small

    // Superfícies (com transparência do core)
    readonly property color base: Colours.tPalette.m3surface
    readonly property color mantle: Colours.tPalette.m3surfaceContainerLow
    readonly property color crust: Colours.tPalette.m3surfaceContainerLowest
    readonly property color surface0: Colours.tPalette.m3surfaceContainer
    readonly property color surface1: Colours.tPalette.m3surfaceContainerHigh
    readonly property color surface2: Colours.tPalette.m3surfaceContainerHighest

    // Conteúdo / texto
    readonly property color text: Colours.palette.m3onSurface
    readonly property color subtext0: Colours.palette.m3onSurfaceVariant
    readonly property color subtext1: Colours.palette.m3onSurfaceVariant

    // Camadas/bordas (Catppuccin overlay0..2), adicionadas p/ o WhatsApp
    readonly property color overlay0: Colours.palette.m3outlineVariant
    readonly property color overlay1: Colours.palette.m3outline
    readonly property color overlay2: Colours.palette.m3onSurfaceVariant

    // Acentos Catppuccin -> papéis m3 mais próximos (os acentos não têm
    // correspondência exata em m3; mantidos distintos para a paleta do desenho).
    readonly property color mauve: Colours.palette.m3primary
    readonly property color blue: Colours.palette.m3secondary
    readonly property color sapphire: Colours.palette.m3tertiary
    readonly property color green: Colours.palette.m3success
    readonly property color red: Colours.palette.m3error
    readonly property color peach: Colours.palette.m3tertiaryContainer
    readonly property color yellow: Colours.palette.m3secondaryContainer
}
