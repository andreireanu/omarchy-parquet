import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Parquet.js" as Parquet

// Parquet's tile editor: a fullscreen overlay over the layout library. Click a
// zone to select it; V / H (or double-click) split it, Del merges it into its
// neighbour, drag a divider to set the ratio. Save writes the layout back to
// state.json — every workspace on that layout follows.
//
// The toolbar lists the whole library: clicking one switches which layout you
// are editing. Saving, renaming and deleting all keep the editor OPEN so you
// can work through several layouts in one visit — only Cancel, Esc and the
// backdrop close it.
//
// Summoned by the bar widget / panel:
//   omarchy-shell shell summon io.github.andreireanu.parquet '{"layout":"coding"}'
//   omarchy-shell shell summon io.github.andreireanu.parquet '{"new":true,"workspace":3}'
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int wsid: 0
  property bool isNew: false
  property string layoutName: ""          // "" while a new layout is unnamed
  property var tree: Parquet.clone(Parquet.FALLBACK_TREE)
  property var selectedPath: null
  property bool confirmDelete: false
  // The tree as it was when the current layout was loaded. Switching layouts
  // from the toolbar would otherwise throw away unsaved edits with no warning.
  property string savedTree: ""
  // Layout the user has clicked but not yet confirmed switching to, while the
  // canvas is dirty. Same two-step idiom as the Delete button.
  property string pendingSwitch: ""
  // Briefly true after a save, so the Save button can say so — the editor no
  // longer closes on save, so that button is the only confirmation there is.
  property bool justSaved: false
  readonly property string pluginId: manifest && manifest.id ? manifest.id : "io.github.andreireanu.parquet"

  // ---- lifecycle -----------------------------------------------------

  function open(payload) {
    var args = {}
    try { args = JSON.parse(payload || "{}") || {} } catch (e) { args = {} }
    root.wsid = parseInt(args.workspace) || service.activeWorkspaceId || 0
    root.confirmDelete = false
    root.selectedPath = null
    root.pendingSwitch = ""

    if (args["new"]) {
      root.isNew = true
      root.layoutName = ""
      root.tree = Parquet.clone(Parquet.FALLBACK_TREE)
      nameField.text = service.suggestName(root.tree)   // editable starting point
    } else {
      root.isNew = false
      root.layoutName = String(args.layout || service.currentLayout(root.wsid) || "")
      // A name that is no longer in the library — deleted or renamed while the
      // picker was open, or a stale summon payload — must not be edited as if
      // it were there. layoutTree() would quietly hand back the FIRST library
      // layout, and the next save would then CREATE a layout under the dead
      // name carrying that other layout's shape. Land on something real.
      if (!root.knownLayout(root.layoutName)) {
        var lib = service.library()
        root.layoutName = lib.length ? lib[0].name : ""
      }
      root.tree = Parquet.clone(service.layoutTree(root.layoutName))
      nameField.text = root.layoutName
    }
    root.savedTree = JSON.stringify(root.tree)
    root.opened = true
    Qt.callLater(function () {
      if (root.isNew) { nameField.forceActiveFocus(); nameField.selectAll() }
      else keyCatcher.forceActiveFocus()
    })
  }

  function close() { root.opened = false }
  function dismiss() {
    root.close()
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
  }

  // ---- tree edits --------------------------------------------------

  // Is this name actually in the library right now?
  function knownLayout(name) {
    if (!name) return false
    var lib = service.library()
    for (var i = 0; i < lib.length; i++) if (lib[i].name === name) return true
    return false
  }

  // True when the canvas or the name has changed since this layout was loaded.
  function isDirty() {
    if (JSON.stringify(root.tree) !== root.savedTree) return true
    var typed = nameField.text.trim()
    return root.isNew ? typed.length > 0 : (typed !== root.layoutName)
  }

  // Clicking a layout in the toolbar switches which layout you are editing —
  // its real tree AND its real name — rather than copying its shape onto the
  // layout you already had open. Dirty canvas: the button asks once first, the
  // same way Delete does, so unsaved zones are never dropped on a stray click.
  function switchTo(name) {
    if (!root.isNew && name === root.layoutName) { root.pendingSwitch = ""; return }
    if (root.pendingSwitch !== name && root.isDirty()) { root.pendingSwitch = name; return }
    root.loadLayout(name)
  }

  function loadLayout(name) {
    root.isNew = false
    root.layoutName = name
    root.tree = Parquet.clone(service.layoutTree(name))
    root.savedTree = JSON.stringify(root.tree)
    root.selectedPath = null
    root.confirmDelete = false
    root.pendingSwitch = ""
    nameField.text = name
  }

  function splitSelected(side) {
    if (!root.selectedPath) return
    var rects = Parquet.leafRects(root.tree, 0, 0, 1, 1)
    var target = null
    for (var i = 0; i < rects.length; i++)
      if (Parquet.samePath(rects[i].path, root.selectedPath)) target = rects[i]
    if (!target) return
    root.tree = Parquet.splitLeaf(root.tree, root.selectedPath, side, target.w, target.h)
    root.selectedPath = root.selectedPath.concat("first")
    root.pendingSwitch = ""
    root.justSaved = false
  }

  function mergeSelected() {
    if (!root.selectedPath || root.selectedPath.length === 0) return
    root.tree = Parquet.mergeLeaf(root.tree, root.selectedPath)
    root.selectedPath = null
    root.pendingSwitch = ""
    root.justSaved = false
  }

  function setRatio(path, ratio) {
    root.tree = Parquet.setRatio(root.tree, path, Parquet.snapRatio(ratio))
    root.pendingSwitch = ""
    root.justSaved = false
  }

  // ---- save / delete ---------------------------------------------

  // Save, rename and delete all leave the editor OPEN, so you can keep working
  // through the library in one visit. Only Cancel, Esc and a click on the
  // backdrop close it. Because nothing closes on save, the Save button doubles
  // as the confirmation — it reads "Saved" for a moment afterwards.
  function save() {
    var wanted = nameField.text.trim()
    if (!wanted) return                       // name is required

    if (root.isNew || !root.layoutName) {
      var created = service.createLayout(wanted, root.tree)
      if (root.wsid > 0) service.applyLayout(root.wsid, created)
      root.isNew = false
      root.layoutName = created               // may be deduped ("mine" -> "mine 2")
      nameField.text = created
    } else {
      var name = root.layoutName
      if (wanted !== root.layoutName)
        name = service.renameLayout(root.layoutName, wanted)
      service.saveLayout(name, root.tree)
      root.layoutName = name
      nameField.text = name                   // ditto, if the rename deduped
    }
    // The canvas is now what is on disk, so it is no longer dirty and switching
    // layouts should not ask to discard anything.
    root.savedTree = JSON.stringify(root.tree)
    root.pendingSwitch = ""
    root.confirmDelete = false
    root.justSaved = true
    savedFlash.restart()
  }

  function requestDelete() {
    if (root.isNew) { root.dismiss(); return }   // nothing saved yet to delete
    if (!root.confirmDelete) { root.confirmDelete = true; return }

    var gone = root.layoutName
    service.deleteLayout(gone)
    root.confirmDelete = false

    // deleteLayout refuses to remove the last layout standing; if it is still
    // there, the delete was declined and there is nothing to move on to.
    var lib = service.library()
    var next = ""
    for (var i = 0; i < lib.length; i++) {
      if (lib[i].name === gone) return
      if (!next) next = lib[i].name
    }
    if (next) root.loadLayout(next)            // carry on editing the next one
    else root.dismiss()
  }

  Timer { id: savedFlash; interval: 1400; onTriggered: root.justSaved = false }

  Service { id: service }

  // ---- surface ---------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-parquet-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    readonly property real screenAspect: (panel.screen && panel.screen.height > 0)
      ? panel.screen.width / panel.screen.height : (16 / 9)

    Rectangle { anchors.fill: parent; color: Qt.rgba(0, 0, 0, 0.78) }

    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onPressed: function (event) {
        if (nameField.activeFocus) return
        if (event.key === Qt.Key_Escape) { root.dismiss(); event.accepted = true }
        else if (event.key === Qt.Key_Delete || event.key === Qt.Key_Backspace) { root.mergeSelected(); event.accepted = true }
        else if (event.key === Qt.Key_V) { root.splitSelected("left"); event.accepted = true }
        else if (event.key === Qt.Key_H) { root.splitSelected("top"); event.accepted = true }
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.save(); event.accepted = true }
      }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Math.round(panel.height * 0.04)
      spacing: 16

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: toolbarRow.implicitHeight + 20
        color: Color.menu.background
        radius: Style.cornerRadius
        border.color: Color.menu.border
        border.width: 1

        MouseArea { anchors.fill: parent; onClicked: {} }

        RowLayout {
          id: toolbarRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: 12
          anchors.rightMargin: 12
          spacing: 8

          ZoneMark {
            implicitWidth: Style.font.body * 1.6
            implicitHeight: Style.font.body * 1.6
            tree: root.tree
            filled: true
            color: Color.menu.text
          }

          Text {
            text: root.isNew ? "Name" : "Rename"
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          TextField {
            id: nameField
            // Grows with the name instead of sitting at a fixed 170px. A long
            // name used to scroll out of the box, so you could not see WHICH
            // layout you were editing — which made the "Start from" buttons
            // look like they had failed to switch layouts, when in fact they
            // only ever replace the canvas shape.
            Layout.preferredWidth: Math.max(Style.space(170),
                                    Math.min(Style.space(380),
                                             nameField.contentWidth + Style.space(26)))
            placeholderText: "layout name"
            foreground: Color.menu.text
            accent: Color.accent
            onAccepted: if (nameField.text.trim()) root.save()
          }

          Item { implicitWidth: 8 }

          Text {
            text: "Edit"
            color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          // The library grows without limit and the names are arbitrary, so this
          // is the one part of the toolbar allowed to run out of room: it takes
          // whatever is left after the name field and the action buttons, clips,
          // and scrolls sideways. Previously the buttons kept their natural
          // width and ran straight over Delete / Cancel / Save — a RowLayout
          // will happily overflow its own anchored width.
          //
          // This is also the only fillWidth item in the row, so when the library
          // IS narrow the slack sits inside the Flickable and the action buttons
          // stay right-aligned exactly as before.
          Item {
            id: shapeArea
            Layout.fillWidth: true
            Layout.preferredHeight: shapeStrip.implicitHeight

            Flickable {
              id: shapeRow
              anchors.fill: parent
              contentWidth: shapeStrip.implicitWidth
              contentHeight: height
              clip: true
              flickableDirection: Flickable.HorizontalFlick
              boundsBehavior: Flickable.StopAtBounds

              readonly property real maxScroll: Math.max(0, contentWidth - width)

              // A wheel — or a trackpad's sideways delta — scrolls it sideways.
              WheelHandler {
                onWheel: function (event) {
                  var d = event.angleDelta.x !== 0 ? event.angleDelta.x : event.angleDelta.y
                  shapeRow.contentX = Math.max(0, Math.min(shapeRow.maxScroll,
                                                           shapeRow.contentX - d))
                }
              }

              RowLayout {
                id: shapeStrip
                spacing: 8

                Repeater {
                  model: service.library()
                  Button {
                    required property var modelData
                    // Every layout is listed, including the one being edited —
                    // highlighted, so the strip also answers "which am I on?".
                    readonly property bool isCurrent:
                      !root.isNew && modelData.name === root.layoutName
                    text: root.pendingSwitch === modelData.name
                            ? "Discard changes?" : modelData.name
                    selected: isCurrent
                    fontSize: Style.font.bodySmall
                    bordered: true
                    tooltipText: isCurrent
                      ? ("Editing " + modelData.name)
                      : (root.pendingSwitch === modelData.name
                          ? ("Click again to leave unsaved changes and edit " + modelData.name)
                          : ("Edit " + modelData.name))
                    onClicked: root.switchTo(modelData.name)
                  }
                }
              }
            }

            // Edge fades — siblings of the Flickable, not children, or they
            // would sit in its contentItem and scroll away with the buttons.
            // They mark a clipped strip as scrollable rather than cut off.
            Rectangle {
              anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
              width: 14
              visible: shapeRow.contentX > 1
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: Color.menu.background }
                GradientStop { position: 1.0; color: "transparent" }
              }
            }
            Rectangle {
              anchors { right: parent.right; top: parent.top; bottom: parent.bottom }
              width: 14
              visible: shapeRow.contentX < shapeRow.maxScroll - 1
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0.0; color: "transparent" }
                GradientStop { position: 1.0; color: Color.menu.background }
              }
            }
          }

          Button {
            visible: !root.isNew
            text: root.confirmDelete
              ? ("Delete? " + (service.layoutInUse(root.layoutName).length
                  ? "used by ws " + service.layoutInUse(root.layoutName).join(", ") : "confirm"))
              : "Delete"
            bordered: true
            onClicked: root.requestDelete()
          }
          Button { text: "Cancel"; bordered: true; onClicked: root.dismiss() }
          Button {
            // The editor stays open on save, so this label is the only signal
            // that anything happened.
            text: root.justSaved ? "Saved" : (root.isNew ? "Create" : "Save")
            bordered: true
            accent: Color.accent
            selected: true
            enabled: nameField.text.trim().length > 0
            tooltipText: nameField.text.trim().length > 0 ? "" : "Give the layout a name first"
            onClicked: root.save()
          }
        }
      }

      Item {
        Layout.fillWidth: true
        Layout.fillHeight: true

        Rectangle {
          id: canvas
          anchors.centerIn: parent
          width: Math.min(parent.width, parent.height * panel.screenAspect)
          height: width / panel.screenAspect
          color: "transparent"
          border.color: Qt.rgba(1, 1, 1, 0.25)
          border.width: 1

          // The divider being dragged / hovered. A snapshot of the split node
          // (path + its box) taken at press — its box doesn't move during the
          // drag, only the ratio inside it, so this stays valid throughout.
          property var dragNode: null
          property var hoverNode: null
          readonly property real grabPx: 12

          function dividerAt(mx, my) {
            var nodes = Parquet.splitNodes(root.tree, 0, 0, canvas.width, canvas.height)
            var best = null, bestDist = canvas.grabPx
            for (var i = 0; i < nodes.length; i++) {
              var n = nodes[i], d
              if (n.side === "top") {
                if (mx < n.x || mx > n.x + n.w) continue
                d = Math.abs(my - (n.y + n.h * n.ratio))
              } else {
                if (my < n.y || my > n.y + n.h) continue
                d = Math.abs(mx - (n.x + n.w * n.ratio))
              }
              if (d < bestDist) { bestDist = d; best = n }
            }
            return best
          }

          // deselect backdrop (bottom of the stack). Any canvas click also
          // moves keyboard focus off the name field so V / H / Del work.
          MouseArea {
            anchors.fill: parent
            onPressed: keyCatcher.forceActiveFocus()
            onClicked: root.selectedPath = null
          }

          Repeater {
            model: Parquet.leafRects(root.tree, 0, 0, canvas.width, canvas.height)
            Rectangle {
              x: modelData.x
              y: modelData.y
              width: modelData.w
              height: modelData.h
              readonly property bool sel: Parquet.samePath(modelData.path, root.selectedPath)
              color: sel ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
                         : Qt.rgba(1, 1, 1, 0.05)
              border.color: sel ? Color.accent : Qt.rgba(1, 1, 1, 0.35)
              border.width: sel ? 2 : 1

              Text {
                anchors.centerIn: parent
                text: modelData.index + 1
                color: Color.menu.text
                font.pixelSize: Math.min(parent.height, parent.width) * 0.25
                opacity: 0.5
              }

              MouseArea {
                anchors.fill: parent
                anchors.margins: 6
                onPressed: keyCatcher.forceActiveFocus()
                onClicked: root.selectedPath =
                  Parquet.samePath(modelData.path, root.selectedPath) ? null : modelData.path
                onDoubleClicked: {
                  root.selectedPath = modelData.path
                  root.splitSelected(modelData.w >= modelData.h ? "left" : "top")
                }
              }
            }
          }

          // Divider handles — visual only. This Repeater rebuilds on every tree
          // change (so it can't own the drag grab); the drag lives in the one
          // stable MouseArea below.
          Repeater {
            model: Parquet.splitNodes(root.tree, 0, 0, canvas.width, canvas.height)
            Rectangle {
              readonly property bool horiz: modelData.side === "top"
              readonly property real linePos: horiz
                ? modelData.y + modelData.h * modelData.ratio
                : modelData.x + modelData.w * modelData.ratio
              readonly property bool hot:
                (canvas.dragNode && Parquet.samePath(canvas.dragNode.path, modelData.path))
                || (!canvas.dragNode && canvas.hoverNode
                    && Parquet.samePath(canvas.hoverNode.path, modelData.path))
              x: horiz ? modelData.x : linePos - width / 2
              y: horiz ? linePos - height / 2 : modelData.y
              width: horiz ? modelData.w : (hot ? 6 : 3)
              height: horiz ? (hot ? 6 : 3) : modelData.h
              radius: 2
              color: hot ? Color.accent : Qt.rgba(1, 1, 1, 0.3)
            }
          }

          // The one stable drag surface. Not rebuilt by tree changes, so it
          // keeps the mouse grab for the whole drag.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton
            cursorShape: {
              var n = canvas.dragNode || canvas.hoverNode
              return n ? (n.side === "top" ? Qt.SizeVerCursor : Qt.SizeHorCursor) : Qt.ArrowCursor
            }
            onPressed: function (mouse) {
              keyCatcher.forceActiveFocus()
              var n = canvas.dividerAt(mouse.x, mouse.y)
              if (n) { canvas.dragNode = n; mouse.accepted = true }
              else { mouse.accepted = false }   // fall through to zones / backdrop
            }
            onReleased: canvas.dragNode = null
            onCanceled: canvas.dragNode = null
            onPositionChanged: function (mouse) {
              if (canvas.dragNode) {
                var n = canvas.dragNode
                root.setRatio(n.path, n.side === "top"
                  ? (mouse.y - n.y) / n.h
                  : (mouse.x - n.x) / n.w)
              } else {
                canvas.hoverNode = canvas.dividerAt(mouse.x, mouse.y)
              }
            }
            onExited: if (!canvas.dragNode) canvas.hoverNode = null
          }
        }
      }

      Text {
        Layout.fillWidth: true
        horizontalAlignment: Text.AlignHCenter
        color: Qt.rgba(1, 1, 1, 0.72)
        font.pixelSize: Style.font.body
        text: "Click a zone  ·  V split left/right  ·  H split top/bottom  ·  "
          + "Del merge into neighbour  ·  Double-click a zone to split it  ·  "
          + "Drag a divider to resize  ·  Enter save  ·  Esc cancel"
      }
    }
  }
}
