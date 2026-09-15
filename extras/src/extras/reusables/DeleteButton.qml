// Portado de Serpantinum: src/quickshell/reusables/DeleteButton.qml (AGPL-3.0)
// Ajuste de port: import relativo do Serpantinum -> import qs.extras.

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.extras

IconButton {
    id: root
    buttonIcon: "󰆴"
    accentColor: ThemeBackend.red
    textColor: ThemeBackend.crust
}
