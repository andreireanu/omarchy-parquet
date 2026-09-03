import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Parquet's bar chip.
//
// Parquet is a Lua tiling layout (layout/parquet.lua, `lua:parquet`) that drops
// windows into a fixed set of zones. Each workspace names a layout from the
// shared library in ~/.local/state/omarchy/parquet/state.json and has its own
// on/off state.
//
//   Left click   →  toggle Parquet on/off for the focused workspace
//   Right click  →  layout picker popup (Panel.qml)
//   The chip icon is a live thumbnail of the focused workspace's layout,
//   hollow when Parquet is off.
BarWidget {
  id: root
  moduleName: "io.github.andreireanu.parquet"

  readonly property int wsid: service.activeWorkspaceId
  readonly property bool isOn: wsid > 0 && service.enabledFor(wsid)

  // The panel's coordinator (KeyboardPanel) calls back through `owner`, which
  // is this widget — so expose the same open/close/toggle surface djrcx does.
  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() {
    if (panelLoader.item && typeof panelLoader.item.closeForPopoutSwitch === "function")
      panelLoader.item.closeForPopoutSwitch()
  }

  // Left click: flip Parquet for this workspace. On -> off restores the
  // workspace's previous native layout; off -> on re-uses its remembered layout.
  function toggleParquet() {
    if (root.wsid <= 0) return
    if (root.isOn) service.disableWorkspace(root.wsid)
    else service.enableWorkspace(root.wsid)
  }

  // The payload rides inside a single-quoted shell word. Parquet.sanitizeName
  // already keeps quotes out of layout names, but this is the boundary that
  // would actually be crossed, so close it here too: '\'' ends the quote,
  // inserts a literal quote, reopens it.
  function shellQuote(s) {
    return "'" + String(s).replace(/'/g, "'\\''") + "'"
  }

  function openEditor(payload) {
    var obj = payload || {}
    if (obj.workspace === undefined) obj.workspace = root.wsid
    root.bar.run("omarchy-shell shell summon " + root.moduleName
                 + " " + shellQuote(JSON.stringify(obj)))
  }

  // Hand the loaded Panel its host references. Runs from several places because
  // the Loader can finish before `chip` is constructed (see djrcx layout-switcher).
  function injectPanel() {
    var p = panelLoader.item
    if (!p) return
    if ("bar" in p) p.bar = root.bar
    if ("settings" in p) p.settings = root.settings
    if ("anchorItem" in p && chip) p.anchorItem = chip
    if ("hostWidget" in p) p.hostWidget = root
    if ("service" in p) p.service = service
  }

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: injectPanel()

  Service { id: service }

  // Parquet is half QML, half a Hyprland Lua layout, and `omarchy plugin add`
  // only ever clones the QML. Without parquet.lua and the managed hyprland.lua
  // block there is no `lua:parquet` for a workspace rule to name, so the widget
  // would toggle happily and tile nothing. Putting that in place here is what
  // makes `omarchy plugin add <url> --enable` the whole install.
  //
  // `--ensure` is a no-op — and reloads nothing — once everything is current,
  // so this costs one cmp and two greps per shell start.
  readonly property string pluginDir:
    Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  Process {
    id: bootstrap
    command: ["bash", root.pluginDir + "/scripts/install.sh", "--ensure"]
    running: true
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() { service.refreshActiveWorkspace() }
    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (name.indexOf("workspace") !== -1 || name === "configreloaded")
        service.refreshActiveWorkspace()
    }
  }

  Timer {
    interval: 4000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: service.refreshActiveWorkspace()
  }

  WidgetButton {
    id: chip
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    dimmed: !root.isOn
    horizontalMargin: 7
    fixedWidth: root.vertical ? -1 : Math.round(root.barSize * 1.15)
    tooltipText: root.wsid <= 0
      ? "Parquet"
      : ((root.isOn
          ? "Parquet on — workspace " + root.wsid + " · " + service.currentLayout(root.wsid)
          : "Parquet off — workspace " + root.wsid)
         + "\nLeft: turn " + (root.isOn ? "off" : "on") + "   Right: pick a layout")
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggle()   // the picker popup
      else root.toggleParquet()
    }

    ZoneMark {
      anchors.centerIn: parent
      height: Math.round(chip.barSize * 0.56)
      width: height
      // Keep the workspace's chosen layout shape even when Parquet is off
      // (just hollow), so the icon doesn't snap back to a default.
      tree: service.layoutTree(service.displayLayout(root.wsid))
      filled: root.isOn
      color: root.bar ? root.bar.barForeground : Color.foreground
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
