// Caelestia Extras — estado compartilhado do WhatsApp (drawer nativo).
// Copyright (C) 2025 The Caelestia Extras contributors
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or (at your
// option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
// details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
//
// Registro: singleton no qmldir RAIZ do módulo (src/extras/qmldir):
//   singleton WhatsAppState 1.0 whatsapp/WhatsAppState.qml
// O host nativo (WhatsAppDrawer) escuta os pedidos e publica `visible`; o entry
// (Extras.qml, L4) e os atalhos/IPC só disparam showRequested/hideRequested,
// sem conhecer a instância por ecrã.

pragma Singleton

import QtQuick
import Quickshell

Singleton {
    id: root

    // Pedido de abertura/fecho dirigido ao drawer do ecrã focado. Quem escuta
    // decide se age (o drawer só responde quando o seu ecrã está focado).
    signal showRequested()
    signal hideRequested()

    // Espelho lógico da visibilidade do drawer (observável por consumidores).
    property bool visible: false
}
