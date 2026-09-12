// Portado de Serpantinum: src/quickshell/dock/Dock.qml (AGPL-3.0)
// Port para Caelestia (L1): conteúdo visual da dock. SEM StyledWindow, janela de
// exclusão ou fundo próprio — o fundo transparente deixa o blob nativo do core
// (ContentWindow: PanelBg/BlobGroup) aparecer atrás. Exporta implicitWidth/implicitHeight
// e hospeda: grelha de ícones + hover/magnify por distância contínua, drag-reorder,
// app-picker (modo edição) e strip de apps minimizados.
//
// Animação: os Behavior fixos (220 ms OutCubic) foram substituídos por `Anim`
// (qs.components / Tokens) e respeitam `animations`. Hover contínuo via HoverHandler
// no container + mapFromItem (não só pelo índice).

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.components
import qs.services
import qs.extras as Extras
import qs.extras.reusables

Item {
    id: panel

    // ---- API (fornecida pelo DockWrapper) -------------------------------
    property var settings: ({})
    property bool animations: true
    property real elementSize: 44
    property real hoverScale: 1.2
    property bool cascadeScale: true
    property real panelOpacity: 1.0

    readonly property bool hasApps: dockAppsModel.count > 0
    property bool editMode: false

    // Exposto ao DockWrapper (mantém a dock aberta durante o hover).
    readonly property bool hovered: dockContainer.hovered

    // ---- Helpers --------------------------------------------------------
    function s(v) {
        return (typeof Extras !== "undefined" && Extras.Scaler) ? Extras.Scaler.s(v) : v;
    }

    function playSfx(name) {
        if (typeof Extras !== "undefined" && Extras.Sounds)
            Extras.Sounds.playSfx(name);
    }

    // ---- Dimensões ------------------------------------------------------
    readonly property real pad: panel.s(10)
    readonly property real itemSpacing: panel.s(panel.editMode ? 10 : 8)
    readonly property real itemSizeRaw: Math.max(16, panel.s(panel.elementSize))
    readonly property int totalItemCount: dockAppsModel.count
    // Sem apps fixados: reserva um slot para a "pílula" com o botão "+".
    readonly property bool empty: panel.totalItemCount === 0
    readonly property int layoutItemCount: panel.empty ? 1 : panel.totalItemCount

    // Encolhe os ícones se não couberem na largura do ecrã (sem clipping).
    readonly property real availableWidth: (Window.window && Window.window.width > 0) ? Window.window.width - panel.s(80) : 0
    readonly property real maxItemSize: (panel.availableWidth > 0 && panel.totalItemCount > 0)
        ? Math.max(18, (panel.availableWidth - (panel.totalItemCount - 1) * panel.itemSpacing - panel.pad * 2) / panel.totalItemCount)
        : panel.itemSizeRaw
    readonly property real itemSize: Math.min(panel.itemSizeRaw, panel.maxItemSize)
    readonly property real itemStep: panel.itemSize + panel.itemSpacing
    readonly property real contentLength: panel.layoutItemCount > 0
        ? panel.layoutItemCount * panel.itemSize + (panel.layoutItemCount - 1) * panel.itemSpacing
        : 0

    readonly property real hoverDelta: Math.max(0.0, panel.hoverScale - 1.0)

    // Altura da dock e largura mínima da pílula vazia (~2.5x a altura).
    readonly property real pillHeight: panel.itemSize + panel.pad * 2
    readonly property real minPillWidth: panel.pillHeight * 2.5

    // Continua a crescer com elementSize/ícones quando há apps; nunca ~0.
    implicitWidth: panel.empty
        ? Math.round(panel.minPillWidth)
        : Math.round(panel.contentLength + panel.pad * 2)
    implicitHeight: Math.round(panel.pillHeight)

    // ---- Modelo de apps fixados ----------------------------------------
    ListModel {
        id: dockAppsModel
    }

    readonly property var rawDockSettings: (typeof Extras !== "undefined" && Extras.Config && Extras.Config.rawSettings && Extras.Config.rawSettings.dock)
        ? Extras.Config.rawSettings.dock
        : (typeof Extras !== "undefined" && Extras.Config && typeof Extras.Config.getSetting === "function"
            ? Extras.Config.getSetting("dock", ({}))
            : ({}))

    function loadApps() {
        let customApps = panel.settings ? panel.settings.apps : null;
        if (!customApps || !Array.isArray(customApps))
            customApps = [];
        if (dockAppsModel.count === customApps.length) {
            let matches = true;
            for (let i = 0; i < customApps.length; i++) {
                const cur = dockAppsModel.get(i);
                const app = customApps[i];
                const id = app.desktop_id || app.id || "";
                if (!cur || cur.desktop_id !== id || cur.name !== (app.name || "") || cur.icon !== (app.icon || "")) {
                    matches = false;
                    break;
                }
            }
            if (matches)
                return;
        }
        dockAppsModel.clear();
        for (let k = 0; k < customApps.length; k++) {
            const app = customApps[k];
            dockAppsModel.append({
                "name": app.name || "",
                "comment": app.comment || "",
                "desktop_id": app.desktop_id || app.id || "",
                "icon": app.icon || ""
            });
        }
    }

    function saveApps() {
        const arr = [];
        for (let i = 0; i < dockAppsModel.count; i++) {
            const item = dockAppsModel.get(i);
            if (item) {
                arr.push({
                    "name": item.name || "",
                    "comment": item.comment || "",
                    "desktop_id": item.desktop_id || "",
                    "icon": item.icon || ""
                });
            }
        }
        const current = Object.assign({}, panel.rawDockSettings || {});
        current.apps = arr;
        if (typeof Extras !== "undefined" && Extras.Config && typeof Extras.Config.setSetting === "function")
            Extras.Config.setSetting("dock", current);
    }

    function isAppInDock(desktopId) {
        if (!desktopId)
            return false;
        for (let i = 0; i < dockAppsModel.count; i++) {
            const it = dockAppsModel.get(i);
            if (it && it.desktop_id === desktopId)
                return true;
        }
        return false;
    }

    function addApp(entry) {
        if (!entry)
            return;
        const id = entry.id || entry.desktop_id || "";
        if (panel.isAppInDock(id))
            return;
        dockAppsModel.append({
            "name": entry.name || "",
            "comment": entry.comment || "",
            "desktop_id": id,
            "icon": entry.icon || ""
        });
        panel.saveApps();
    }

    function removeAppByDesktopId(desktopId) {
        for (let i = 0; i < dockAppsModel.count; i++) {
            const it = dockAppsModel.get(i);
            if (it && it.desktop_id === desktopId) {
                dockAppsModel.remove(i, 1);
                panel.saveApps();
                return;
            }
        }
    }

    function setEditMode(val) {
        panel.editMode = val;
        panel.playSfx(val ? "guide/barconfig/out.wav" : "guide/barconfig/in.wav");
    }

    function launchApp(desktopId) {
        if (typeof DesktopEntries !== "undefined") {
            const entry = DesktopEntries.byId(desktopId);
            if (entry)
                entry.execute();
        }
    }

    // ---- Drag / drop ----------------------------------------------------
    property int dragSourceIndex: -1
    property int dropTargetIndex: -1

    function calculateDropIndex(mx, my) {
        if (dockAppsModel.count <= 1)
            return 0;
        const step = panel.itemSize + panel.itemSpacing;
        const layoutX = dockViewport.x + dockLayout.x;
        const layoutY = dockViewport.y + dockLayout.y;
        const idx = Math.floor(((mx - layoutX) + panel.itemSpacing / 2) / step);
        return Math.max(0, Math.min(dockAppsModel.count - 1, idx));
    }

    // ---- Picker ---------------------------------------------------------
    property var allDesktopApps: []
    ListModel { id: pickerFilteredModel }

    function loadAllDesktopApps() {
        const list = [];
        if (typeof DesktopEntries !== "undefined" && DesktopEntries.applications && DesktopEntries.applications.values) {
            const entries = DesktopEntries.applications.values;
            for (let i = 0; i < entries.length; i++) {
                const e = entries[i];
                if (e.noDisplay)
                    continue;
                list.push({
                    "id": e.id || "",
                    "name": e.name || "",
                    "comment": e.comment || "",
                    "icon": e.icon || ""
                });
            }
        }
        list.sort((a, b) => (a.name || "").localeCompare(b.name || ""));
        panel.allDesktopApps = list;
        const currentQuery = pickerSearchInput ? (pickerSearchInput.text || "") : "";
        panel.filterPickerApps(currentQuery);
    }

    function filterPickerApps(query) {
        pickerFilteredModel.clear();
        const q = (query || "").trim().toLowerCase();
        for (let i = 0; i < panel.allDesktopApps.length; i++) {
            const app = panel.allDesktopApps[i];
            if (!q || app.name.toLowerCase().includes(q) || app.comment.toLowerCase().includes(q) || app.id.toLowerCase().includes(q)) {
                pickerFilteredModel.append({
                    "id": app.id || "",
                    "name": app.name || "",
                    "comment": app.comment || "",
                    "icon": app.icon || ""
                });
            }
        }
    }

    function grabPickerFocus() {
        if (pickerSearchInput) {
            pickerSearchInput.forceActiveFocus();
            if (typeof pickerSearchInput.forceInputFocus === "function")
                pickerSearchInput.forceInputFocus();
        }
    }

    Timer {
        id: pickerFocusTimer

        interval: 50
        repeat: false
        onTriggered: panel.grabPickerFocus()
    }

    Timer {
        id: pickerFocusRetryTimer

        interval: 150
        repeat: false
        onTriggered: panel.grabPickerFocus()
    }

    onEditModeChanged: {
        dockContainer.hoveredIndex = -1;
        if (panel.editMode) {
            panel.loadAllDesktopApps();
            pickerFocusTimer.restart();
            pickerFocusRetryTimer.restart();
        } else {
            pickerFocusTimer.stop();
            pickerFocusRetryTimer.stop();
            if (pickerSearchInput && typeof pickerSearchInput.clear === "function")
                pickerSearchInput.clear();
        }
    }

    onSettingsChanged: panel.loadApps()

    Component.onCompleted: {
        panel.loadApps();
        panel.loadAllDesktopApps();
    }

    Connections {
        function onValuesChanged() {
            panel.loadAllDesktopApps();
        }

        target: (typeof DesktopEntries !== "undefined" && DesktopEntries.applications) ? DesktopEntries.applications : null
    }

    // ---- Container / hover contínuo ------------------------------------
    Item {
        id: dockContainer

        anchors.fill: parent
        clip: false

        property int hoveredIndex: -1

        readonly property bool hovered: dockHover.hovered
        readonly property bool hoverActive: dockHover.hovered

        // Posição do cursor relativa ao container (HoverHandler no container).
        readonly property real cursorX: dockHover.point.position.x
        readonly property real cursorY: dockHover.point.position.y

        // Cursor mapeado para o sistema de coordenadas do layout (mapFromItem).
        readonly property point cursorInLayout: dockLayout.mapFromItem(dockContainer, dockContainer.cursorX, dockContainer.cursorY)

        HoverHandler {
            id: dockHover

            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onHoveredChanged: {
                if (!hovered)
                    dockContainer.hoveredIndex = -1;
            }
        }

        Item {
            id: dockViewport

            x: Math.round((dockContainer.width - width) / 2)
            y: Math.round((dockContainer.height - height) / 2)
            width: panel.contentLength
            height: panel.itemSize
            visible: width > 0 && height > 0
            clip: false

            GridLayout {
                id: dockLayout

                columns: Math.max(1, panel.totalItemCount)
                rows: 1
                columnSpacing: panel.itemSpacing
                rowSpacing: panel.itemSpacing
                width: implicitWidth
                height: implicitHeight
                x: 0
                y: 0

                Behavior on columnSpacing {
                    enabled: panel.animations

                    Anim {
                        type: Anim.FastSpatial
                    }
                }
                Behavior on rowSpacing {
                    enabled: panel.animations

                    Anim {
                        type: Anim.FastSpatial
                    }
                }

                Repeater {
                    model: dockAppsModel

                    delegate: Item {
                        id: dockButton

                        required property int index
                        required property string name
                        required property string comment
                        required property string desktop_id
                        required property string icon

                        property int itemIndex: index
                        property real popScale: 1.0
                        property real flashOpacity: 0.0
                        property int cornerRadius: Math.round(panel.itemSize * 0.28)
                        property real btnSize: panel.itemSize

                        implicitWidth: panel.itemSize
                        implicitHeight: panel.itemSize
                        Layout.preferredWidth: panel.itemSize
                        Layout.preferredHeight: panel.itemSize
                        Layout.alignment: Qt.AlignVCenter
                        z: isBeingDragged ? 99999 : Math.round(scaleAnim * 100)

                        readonly property bool isDropTarget: panel.dropTargetIndex === index && panel.dragSourceIndex !== index
                        readonly property bool isBeingDragged: btnMa.drag.active
                        readonly property bool dragEnabled: panel.editMode || btnMa.inDragHold
                        readonly property bool canHoverScale: !panel.editMode && panel.dragSourceIndex === -1 && !btnMa.drag.active

                        // Hover por distância contínua (não só índice).
                        readonly property real cursorDistance: {
                            if (!dockContainer.hoverActive || !canHoverScale)
                                return 1000000;
                            const p = dockContainer.cursorInLayout;
                            const cx = dockButton.x + dockButton.width / 2;
                            const cy = dockButton.y + dockButton.height / 2;
                            return Math.hypot(p.x - cx, p.y - cy);
                        }

                        readonly property real influence: {
                            if (!canHoverScale)
                                return 0.0;
                            const radius = panel.cascadeScale ? panel.itemSize * 2.2 : panel.itemSize * 0.75;
                            const d = cursorDistance;
                            if (d >= radius)
                                return 0.0;
                            const t = 1.0 - d / radius;
                            return t * t * (3.0 - 2.0 * t); // smoothstep
                        }

                        readonly property real targetScale: (1.0 + panel.hoverDelta * influence) * (btnMa.pressed ? 0.97 : 1.0)
                        property real scaleAnim: targetScale

                        readonly property real maxShift: Math.min(panel.s(10), panel.itemSize * panel.hoverDelta * 0.65)
                        readonly property real spreadAxis: {
                            if (!panel.cascadeScale || influence <= 0.0)
                                return 0.0;
                            const p = dockContainer.cursorInLayout;
                            const cx = dockButton.x + dockButton.width / 2;
                            const dir = Math.sign(cx - p.x);
                            return (dir === 0 ? 1 : dir) * maxShift * influence;
                        }
                        readonly property real lift: (influence > 0.0 && !panel.editMode) ? panel.s(4) * influence : 0.0

                        // Sem dock vertical por agora: eixo = x, levantamento = -y (rodapé).
                        property real offsetX: (panel.editMode || btnMa.drag.active) ? 0.0 : spreadAxis
                        property real offsetY: (panel.editMode || btnMa.drag.active) ? 0.0 : -lift

                        Behavior on scaleAnim {
                            enabled: panel.animations

                            Anim {
                                type: Anim.FastSpatial
                            }
                        }
                        Behavior on offsetX {
                            enabled: panel.animations

                            Anim {
                                type: Anim.FastSpatial
                            }
                        }
                        Behavior on offsetY {
                            enabled: panel.animations

                            Anim {
                                type: Anim.FastSpatial
                            }
                        }

                        // Placeholder durante o drag.
                        Rectangle {
                            anchors.fill: parent
                            visible: dockButton.isBeingDragged
                            radius: dockButton.cornerRadius
                            color: Qt.alpha(Colours.tPalette.m3surfaceContainerHighest, 0.25)
                            border.color: Qt.alpha(Colours.palette.m3primary, 0.5)
                            border.width: 1
                        }

                        // Indicador de alvo de drop.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -panel.s(3)
                            radius: dockButton.cornerRadius + panel.s(3)
                            color: "transparent"
                            border.color: Colours.palette.m3primary
                            border.width: 2
                            visible: dockButton.isDropTarget
                            opacity: dockButton.isDropTarget ? 1.0 : 0.0

                            Behavior on opacity {
                                enabled: panel.animations

                                NumberAnimation { duration: 140 }
                            }
                        }

                        Item {
                            id: floatWrapper

                            anchors.fill: !btnMa.drag.active ? parent : undefined
                            width: dockButton.btnSize
                            height: dockButton.btnSize
                            z: btnMa.drag.active ? 999999 : 1

                            transform: Translate {
                                x: dockButton.offsetX
                                y: dockButton.offsetY
                            }

                            Drag.active: btnMa.drag.active
                            Drag.source: dockButton
                            Drag.hotSpot.x: width / 2
                            Drag.hotSpot.y: height / 2

                            states: State {
                                when: btnMa.drag.active

                                ParentChange { target: floatWrapper; parent: dragOverlay }
                                PropertyChanges {
                                    floatWrapper.width: dockButton.btnSize
                                    floatWrapper.height: dockButton.btnSize
                                    floatWrapper.scale: 1.15
                                    floatWrapper.opacity: 0.92
                                    floatWrapper.z: 999999
                                }
                            }

                            Rectangle {
                                id: btnShape

                                anchors.fill: parent
                                radius: dockButton.cornerRadius
                                clip: true
                                color: btnMa.pressed
                                    ? Qt.darker(Colours.tPalette.m3surfaceContainer, 1.12)
                                    : (btnMa.containsMouse ? Qt.lighter(Colours.tPalette.m3surfaceContainer, 1.12) : Colours.tPalette.m3surfaceContainer)
                                transformOrigin: Item.Center
                                scale: dockButton.scaleAnim * dockButton.popScale

                                Behavior on color {
                                    ColorAnimation { duration: panel.animations ? 180 : 0 }
                                }

                                SequentialAnimation {
                                    id: btnPopAnim

                                    NumberAnimation { target: dockButton; property: "popScale"; to: 1.1; duration: 110; easing.type: Easing.OutQuad }
                                    NumberAnimation { target: dockButton; property: "popScale"; to: 1.0; duration: 420; easing.type: Easing.OutQuint }
                                }

                                Image {
                                    id: appIcon

                                    anchors.fill: parent
                                    anchors.margins: panel.s(Math.round(panel.elementSize * 0.14))
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    smooth: true
                                    mipmap: true

                                    property bool failedLoad: false

                                    visible: source !== "" && status === Image.Ready && !failedLoad
                                    source: {
                                        const ic = dockButton.icon || "";
                                        if (!ic)
                                            return "";
                                        if (ic.startsWith("file://") || ic.startsWith("image://") || ic.startsWith("http://") || ic.startsWith("https://"))
                                            return ic;
                                        return ic.startsWith("/") ? "file://" + ic : "image://icon/" + ic;
                                    }

                                    onStatusChanged: {
                                        if (status === Image.Error)
                                            failedLoad = true;
                                    }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: appIcon.source === "" || appIcon.failedLoad || appIcon.status === Image.Error
                                    text: dockButton.name ? dockButton.name.charAt(0).toUpperCase() : "?"
                                    font.family: Tokens.font.body.medium.family
                                    font.pixelSize: panel.s(Math.round(panel.elementSize * 0.42))
                                    font.weight: Font.Bold
                                    color: Colours.palette.m3onSurface
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: dockButton.cornerRadius
                                    color: "#ffffff"
                                    opacity: dockButton.flashOpacity

                                    PropertyAnimation on opacity {
                                        id: btnFlashAnim

                                        to: 0
                                        duration: panel.animations ? 400 : 0
                                        easing.type: Easing.OutExpo
                                    }
                                }
                            }

                            MouseArea {
                                id: btnMa

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: (panel.editMode || inDragHold)
                                    ? (drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor)
                                    : Qt.PointingHandCursor
                                pressAndHoldInterval: 350
                                drag.target: floatWrapper
                                drag.axis: Drag.XAndYAxis
                                drag.threshold: (panel.editMode || inDragHold) ? 5 : 99999

                                property bool inDragHold: false

                                onEntered: {
                                    if (dockButton.canHoverScale)
                                        dockContainer.hoveredIndex = dockButton.itemIndex;
                                }

                                onPressed: {
                                    inDragHold = false;
                                    if (panel.editMode) {
                                        panel.dragSourceIndex = dockButton.itemIndex;
                                        panel.dropTargetIndex = dockButton.itemIndex;
                                        panel.playSfx("guide/barconfig/out.wav");
                                    }
                                }

                                onPressAndHold: {
                                    inDragHold = true;
                                    if (!panel.editMode)
                                        panel.setEditMode(true);
                                    panel.dragSourceIndex = dockButton.itemIndex;
                                    panel.dropTargetIndex = dockButton.itemIndex;
                                    panel.playSfx("guide/barconfig/out.wav");
                                }

                                onPositionChanged: function(mouse) {
                                    if ((panel.editMode || inDragHold) && drag.active) {
                                        const pt = btnMa.mapToItem(dockContainer, mouse.x, mouse.y);
                                        panel.dropTargetIndex = panel.calculateDropIndex(pt.x, pt.y);
                                    }
                                }

                                onReleased: {
                                    const wasHold = inDragHold;
                                    inDragHold = false;
                                    if (panel.editMode || wasHold) {
                                        const wasDragging = drag.active;
                                        floatWrapper.Drag.drop();
                                        if (wasDragging) {
                                            const pt = btnMa.mapToItem(dockContainer, btnMa.mouseX, btnMa.mouseY);
                                            const fwPos = floatWrapper.mapToItem(dockContainer, 0, 0);
                                            const completelyOutside = (fwPos.x + floatWrapper.width <= 0 || fwPos.x >= dockContainer.width
                                                || fwPos.y + floatWrapper.height <= 0 || fwPos.y >= dockContainer.height)
                                                || (pt.x < -panel.s(16) || pt.x > dockContainer.width + panel.s(16)
                                                    || pt.y < -panel.s(16) || pt.y > dockContainer.height + panel.s(16));
                                            if (completelyOutside) {
                                                panel.playSfx("guide/barconfig/in.wav");
                                                if (dockButton.desktop_id && dockButton.desktop_id !== "")
                                                    panel.removeAppByDesktopId(dockButton.desktop_id);
                                                else if (panel.dragSourceIndex >= 0 && panel.dragSourceIndex < dockAppsModel.count) {
                                                    dockAppsModel.remove(panel.dragSourceIndex, 1);
                                                    panel.saveApps();
                                                }
                                            } else if (panel.dragSourceIndex !== -1 && panel.dropTargetIndex !== -1 && panel.dragSourceIndex !== panel.dropTargetIndex) {
                                                panel.playSfx("guide/barconfig/in.wav");
                                                dockAppsModel.move(panel.dragSourceIndex, panel.dropTargetIndex, 1);
                                                panel.saveApps();
                                            } else {
                                                panel.playSfx("guide/barconfig/in.wav");
                                            }
                                        }
                                        panel.dragSourceIndex = -1;
                                        panel.dropTargetIndex = -1;
                                        floatWrapper.x = 0;
                                        floatWrapper.y = 0;
                                    }
                                }

                                onClicked: {
                                    if (panel.editMode || inDragHold || drag.active)
                                        return;
                                    if (panel.animations) {
                                        btnPopAnim.start();
                                        dockButton.flashOpacity = 0.4;
                                        btnFlashAnim.start();
                                    }
                                    panel.playSfx("reusables/iconbutton/click.wav");
                                    panel.launchApp(dockButton.desktop_id);
                                }
                            }
                        }
                    }
                }
            }

            // Pílula vazia: botão "+" que abre o app-picker (reutiliza o setEditMode).
            Item {
                id: addButton

                anchors.centerIn: parent
                width: panel.itemSize
                height: panel.itemSize
                visible: panel.empty

                readonly property point center: dockContainer.mapFromItem(addButton, addButton.width / 2, addButton.height / 2)
                readonly property real cursorDistance: {
                    if (!dockContainer.hoverActive)
                        return 1000000;
                    return Math.hypot(dockContainer.cursorX - center.x, dockContainer.cursorY - center.y);
                }
                readonly property real influence: {
                    const radius = panel.itemSize * 1.4;
                    const d = cursorDistance;
                    if (d >= radius)
                        return 0.0;
                    const t = 1.0 - d / radius;
                    return t * t * (3.0 - 2.0 * t);
                }
                property real scaleAnim: 1.0 + panel.hoverDelta * influence

                Behavior on scaleAnim {
                    enabled: panel.animations

                    Anim {
                        type: Anim.FastSpatial
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Math.round(panel.itemSize * 0.3)
                    color: addMa.pressed
                        ? Qt.darker(Colours.tPalette.m3surfaceContainer, 1.12)
                        : (addMa.containsMouse ? Qt.lighter(Colours.tPalette.m3surfaceContainer, 1.12) : Colours.tPalette.m3surfaceContainer)
                    scale: addButton.scaleAnim
                    transformOrigin: Item.Center

                    Behavior on color {
                        ColorAnimation { duration: panel.animations ? 180 : 0 }
                    }

                    MaterialIcon {
                        anchors.centerIn: parent
                        text: "add"
                        color: Colours.palette.m3onSurface
                        fontStyle: Tokens.font.icon.medium
                    }
                }

                MouseArea {
                    id: addMa

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.setEditMode(true)
                }
            }
        }
    }

    // Overlay de drag (acima de tudo).
    Item {
        id: dragOverlay

        anchors.fill: parent
        z: 999999
    }

    // ---- Strip de minimizados ------------------------------------------
    Item {
        id: minimizedStrip

        visible: minimizedAppsModel.count > 0 && !panel.editMode
        width: minimizedAppsModel.count * (btnSize + panel.s(6)) - panel.s(6) + stripPad * 2
        height: btnSize + stripPad * 2
        x: Math.round((panel.width - width) / 2)
        y: -height - panel.s(8)

        property real btnSize: panel.s(Math.max(24, Math.round(panel.elementSize * 0.72)))
        property real stripPad: panel.s(6)

        ListModel { id: minimizedAppsModel }

        function loadMinimized() {
            let arr = [];
            try {
                arr = JSON.parse(minimizedStateFile.text());
            } catch (e) {
                arr = [];
            }
            if (!Array.isArray(arr))
                arr = [];
            minimizedAppsModel.clear();
            for (let i = 0; i < arr.length; i++) {
                const it = arr[i] || {};
                minimizedAppsModel.append({
                    "address": it.address || "",
                    "cls": it.class || "",
                    "title": it.title || ""
                });
            }
        }

        FileView {
            id: minimizedStateFile

            // Caminho intacto (compat Serpantinum): Caching.getStateDir("dock").
            path: Extras.Caching.getStateDir("dock") + "/minimized.json"
            watchChanges: true
            onLoaded: minimizedStrip.loadMinimized()
            onFileChanged: minimizedStrip.loadMinimized()
        }

        Rectangle {
            anchors.fill: parent
            radius: Tokens.rounding.medium
            color: Qt.alpha(Colours.tPalette.m3surface, 0.85)
            border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.6)
            border.width: 1
        }

        RowLayout {
            anchors.fill: parent
            anchors.margins: minimizedStrip.stripPad
            spacing: panel.s(6)

            Repeater {
                model: minimizedAppsModel

                delegate: Rectangle {
                    id: minButton

                    required property string address
                    required property string cls
                    required property string title

                    implicitWidth: minimizedStrip.btnSize
                    implicitHeight: minimizedStrip.btnSize
                    Layout.preferredWidth: minimizedStrip.btnSize
                    Layout.preferredHeight: minimizedStrip.btnSize
                    radius: Math.round(minimizedStrip.btnSize * 0.28)
                    color: minBtnMa.containsMouse
                        ? Qt.lighter(Colours.tPalette.m3surfaceContainer, 1.12)
                        : Colours.tPalette.m3surfaceContainer
                    border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.6)
                    border.width: 1
                    clip: true

                    property string iconName: (cls || "").toLowerCase()

                    Image {
                        id: minAppIcon

                        anchors.fill: parent
                        anchors.margins: minimizedStrip.stripPad
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                        mipmap: true
                        visible: status === Image.Ready
                        source: minButton.iconName !== "" ? "image://icon/" + minButton.iconName : ""
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: minAppIcon.status === Image.Error || minButton.iconName === ""
                        text: (minButton.title || "?").charAt(0).toUpperCase()
                        font.family: Tokens.font.body.medium.family
                        font.pixelSize: Math.round(minimizedStrip.btnSize * 0.42)
                        font.weight: Font.Bold
                        color: Colours.palette.m3onSurface
                    }

                    MouseArea {
                        id: minBtnMa

                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        hoverEnabled: true
                        onClicked: {
                            if (minButton.address !== "") {
                                // Caminho intacto (compat Serpantinum): scripts/minimize.sh.
                                Quickshell.execDetached(["bash", Extras.Caching.serpantinumDir + "/scripts/minimize.sh", "restore", minButton.address]);
                            }
                        }
                    }
                }
            }
        }
    }

    // ---- App picker (modo edição) --------------------------------------
    Item {
        id: appPicker

        visible: panel.editMode || opacity > 0.001
        opacity: panel.editMode ? 1.0 : 0.0
        scale: panel.editMode ? 1.0 : 0.94
        z: 100
        width: Math.min(panel.s(480), Math.max(panel.s(300), panel.width))
        height: animatedPickerHeight
        x: Math.round((panel.width - width) / 2)
        y: -height - panel.s(8)

        property int maxPickerItems: 6
        property int targetItemCount: pickerFilteredModel.count > 0 ? Math.min(pickerFilteredModel.count, maxPickerItems) : maxPickerItems
        property real targetPickerHeight: panel.s(70) + targetItemCount * panel.s(48)
        property real animatedPickerHeight: targetPickerHeight

        Behavior on opacity {
            enabled: panel.animations

            Anim {
                type: Anim.DefaultEffects
            }
        }
        Behavior on scale {
            enabled: panel.animations

            Anim {
                type: Anim.Emphasized
            }
        }
        Behavior on animatedPickerHeight {
            enabled: panel.animations

            Anim {
                type: Anim.FastSpatial
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Tokens.rounding.extraLarge
            color: Colours.tPalette.m3surface
            border.width: 1
            border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.45)
            clip: true

            Item {
                id: pickerContent

                anchors.fill: parent
                anchors.margins: panel.s(12)

                RowLayout {
                    id: pickerSearchRow

                    anchors.left: parent.left
                    anchors.right: parent.right
                    y: 0
                    height: panel.s(34)
                    spacing: panel.s(8)

                    Input {
                        id: pickerSearchInput

                        Layout.fillWidth: true
                        Layout.preferredHeight: panel.s(34)
                        placeholderText: Extras.I18n.t("guide.dock.picker.search", "Search apps...")
                        baseColor: Colours.tPalette.m3surfaceContainer
                        accentColor: Colours.palette.m3primary
                        textColor: Colours.palette.m3onSurface
                        subTextColor: Colours.palette.m3onSurfaceVariant
                        borderColor: Qt.alpha(Colours.palette.m3outlineVariant, 0.6)
                        cornerRadius: Tokens.rounding.small
                        fontPixelSize: panel.s(11)
                        showClearButton: true
                        focus: panel.editMode
                        onTextEdited: function(newText) {
                            panel.filterPickerApps(newText);
                        }
                        onCleared: panel.filterPickerApps("")
                        Keys.onEscapePressed: function(event) {
                            panel.setEditMode(false);
                            event.accepted = true;
                        }
                    }

                    ClickButton {
                        implicitHeight: panel.s(34)
                        maxWidth: panel.s(70)
                        cornerRadius: Tokens.rounding.small
                        buttonText: Extras.I18n.t("guide.dock.picker.done", "Done")
                        textFontSize: panel.s(11)
                        onClicked: panel.setEditMode(false)
                    }
                }

                Rectangle {
                    id: pickerDivider

                    anchors.left: parent.left
                    anchors.right: parent.right
                    y: pickerSearchRow.y + pickerSearchRow.height + panel.s(10)
                    height: 1
                    color: Qt.alpha(Colours.palette.m3outlineVariant, 0.3)
                }

                Item {
                    id: pickerListWrapper

                    anchors.left: parent.left
                    anchors.right: parent.right
                    y: pickerDivider.y + pickerDivider.height + panel.s(10)
                    height: Math.max(0, parent.height - y)
                    clip: true

                    ListView {
                        id: pickerList

                        anchors.fill: parent
                        clip: true
                        model: pickerFilteredModel
                        spacing: panel.s(4)
                        boundsBehavior: Flickable.StopAtBounds

                        ScrollBar.vertical: ScrollBar {
                            active: parent.moving || parent.movingVertically
                            width: panel.s(4)
                            policy: ScrollBar.AsNeeded

                            contentItem: Rectangle {
                                implicitWidth: panel.s(4)
                                radius: panel.s(2)
                                color: Colours.tPalette.m3surfaceContainerHighest
                            }
                        }

                        delegate: Rectangle {
                            id: pickerDelegate

                            required property int index
                            required property string id
                            required property string name
                            required property string comment
                            required property string icon

                            width: pickerList.width - panel.s(6)
                            height: panel.s(44)
                            radius: Tokens.rounding.small
                            readonly property bool isAdded: panel.isAppInDock(pickerDelegate.id)
                            color: isAdded
                                ? Colours.palette.m3primary
                                : (pickerMa.containsMouse ? Qt.alpha(Colours.palette.m3outlineVariant, 0.35) : Qt.alpha(Colours.tPalette.m3surfaceContainer, 0.25))
                            border.width: 0

                            Behavior on color {
                                enabled: panel.animations

                                ColorAnimation { duration: 150 }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: panel.s(8)
                                anchors.rightMargin: panel.s(8)
                                spacing: panel.s(8)

                                Rectangle {
                                    implicitWidth: panel.s(28)
                                    implicitHeight: panel.s(28)
                                    Layout.alignment: Qt.AlignVCenter
                                    radius: Math.round(panel.s(28) * 0.28)
                                    color: pickerDelegate.isAdded
                                        ? Qt.tint(Colours.tPalette.m3surfaceContainer, Qt.rgba(Colours.palette.m3primary.r, Colours.palette.m3primary.g, Colours.palette.m3primary.b, 0.2))
                                        : Colours.tPalette.m3surfaceContainer
                                    clip: true

                                    Image {
                                        id: pIcon

                                        anchors.fill: parent
                                        anchors.margins: panel.s(3)
                                        fillMode: Image.PreserveAspectFit
                                        asynchronous: true
                                        smooth: true
                                        mipmap: true

                                        property bool failedLoad: false

                                        visible: source !== "" && status === Image.Ready && !failedLoad
                                        source: {
                                            const ic = pickerDelegate.icon || "";
                                            if (!ic)
                                                return "";
                                            if (ic.startsWith("file://") || ic.startsWith("image://") || ic.startsWith("http://") || ic.startsWith("https://"))
                                                return ic;
                                            return ic.startsWith("/") ? "file://" + ic : "image://icon/" + ic;
                                        }

                                        onStatusChanged: {
                                            if (status === Image.Error)
                                                failedLoad = true;
                                        }
                                    }

                                    Text {
                                        anchors.centerIn: parent
                                        visible: pIcon.source === "" || pIcon.failedLoad || pIcon.status === Image.Error
                                        text: pickerDelegate.name ? pickerDelegate.name.charAt(0).toUpperCase() : "?"
                                        font.family: Tokens.font.body.medium.family
                                        font.pixelSize: panel.s(12)
                                        font.bold: true
                                        color: pickerDelegate.isAdded ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: panel.s(1)

                                    Text {
                                        text: pickerDelegate.name || pickerDelegate.id
                                        font.family: Tokens.font.body.medium.family
                                        font.pixelSize: panel.s(11)
                                        font.weight: pickerDelegate.isAdded ? Font.Bold : Font.Medium
                                        color: pickerDelegate.isAdded ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }

                                    Text {
                                        text: pickerDelegate.comment || pickerDelegate.id
                                        font.family: Tokens.font.body.medium.family
                                        font.pixelSize: panel.s(9)
                                        color: pickerDelegate.isAdded ? Colours.palette.m3onPrimary : Colours.palette.m3onSurfaceVariant
                                        opacity: 0.85
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                }
                            }

                            MouseArea {
                                id: pickerMa

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    panel.playSfx("reusables/iconbutton/click.wav");
                                    if (pickerDelegate.isAdded)
                                        panel.removeAppByDesktopId(pickerDelegate.id);
                                    else
                                        panel.addApp({
                                            "id": pickerDelegate.id,
                                            "name": pickerDelegate.name,
                                            "comment": pickerDelegate.comment,
                                            "icon": pickerDelegate.icon
                                        });
                                }
                            }
                        }
                    }

                    Item {
                        anchors.fill: parent
                        visible: pickerFilteredModel.count === 0

                        Text {
                            anchors.centerIn: parent
                            text: Extras.I18n.t("guide.dock.picker.empty", "No matching applications")
                            font.family: Tokens.font.body.medium.family
                            font.pixelSize: panel.s(11)
                            color: Colours.palette.m3onSurfaceVariant
                        }
                    }
                }
            }
        }
    }
}
