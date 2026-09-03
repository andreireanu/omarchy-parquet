import QtQuick
import Quickshell
import Quickshell.Io
import "Parquet.js" as Parquet

// Shared state + side-effects for the Parquet widget, panel and editor.
//
// The single source of truth is  ~/.local/state/omarchy/parquet/state.json :
// a layout library plus a per-workspace pointer into it. Written here, re-read
// by layout/parquet.lua on every `reload`. Every Parquet QML piece instantiates
// one of these; FileView.watchChanges keeps them in step.
Item {
  id: root

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string stateHome: {
    var v = Quickshell.env("XDG_STATE_HOME")
    return v && String(v).length ? String(v) : (homeDir + "/.local/state")
  }
  readonly property string stateDir: stateHome + "/omarchy/parquet"
  readonly property string statePath: stateDir + "/state.json"

  readonly property string configHome: {
    var v = Quickshell.env("XDG_CONFIG_HOME")
    return v && String(v).length ? String(v) : (homeDir + "/.config")
  }
  readonly property string hyprDir: configHome + "/hypr"

  // Where this plugin was loaded from — BarWidget.qml passes it in. runSetup()
  // is the only thing that uses it, and it is the only place in this plugin
  // that runs a script.
  property string pluginDir: ""

  // Normalized, always seeded. Bindings that call the accessors re-run on change.
  property var stateData: Parquet.normalizeState(null)

  property int activeWorkspaceId: 0
  property string activeWorkspaceLayout: ""

  property bool _writing: false
  property bool _reloadAfterSave: false
  property int _disableWs: -1
  property bool _dirEnsured: false
  property var _pendingCmds: []

  // ---- setup (the Hyprland half) ---------------------------------------
  //
  // Parquet tiles through a Hyprland Lua layout, and `omarchy plugin add` only
  // ever clones this QML. The layout has to be written to ~/.config/hypr, which
  // is the user's own compositor config — so the widget READS the two files
  // below to say whether that step is done, and installing is a click on the
  // setup card in Panel.qml. Nothing here runs on load.
  //
  //   needsSetup   the Lua half is missing: the picker cannot tile yet
  //   needsUpdate  it is there, but older than the copy this plugin ships
  //                (what `omarchy plugin update` leaves behind)
  property bool _blockPresent: false
  property string _installedVersion: ""
  property string _shippedVersion: ""
  // The three probes below land asynchronously; report nothing until they have
  // all answered, or the bar flashes "setup unfinished" on every shell start.
  property int _probesDone: 0
  readonly property bool setupKnown: _probesDone >= 3

  readonly property bool needsSetup:
    setupKnown && (!_blockPresent || _installedVersion === "")
  readonly property bool needsUpdate:
    setupKnown && !needsSetup && _shippedVersion !== ""
    && _installedVersion !== _shippedVersion

  property bool setupRunning: false
  property string setupError: ""

  function _probed() { root._probesDone = Math.min(3, root._probesDone + 1) }

  // The ONE place this plugin runs its installer: from the setup card's button,
  // after the user has read what it will do. `--ensure` is a no-op when the
  // Hyprland half is already current, and refuses outright on a machine whose
  // compositor config it cannot safely edit.
  function runSetup() {
    if (root.setupRunning || !root.pluginDir.length) return
    root.setupError = ""
    root.setupRunning = true
    setupProc.command = ["/bin/bash", root.pluginDir + "/scripts/install.sh", "--ensure"]
    setupProc.running = true
  }

  // Re-read the two files after a setup run so the card goes away on its own.
  function recheckSetup() {
    root._probesDone = 0
    hyprlandLuaFile.reload()
    installedLayoutFile.reload()
    shippedLayoutFile.reload()
  }

  // ---- reads -----------------------------------------------------------

  function library() { return Parquet.libraryList(root.stateData) }
  function layoutTree(name) { return Parquet.layoutTree(root.stateData, name) }
  function currentLayout(wsid) { return Parquet.currentLayout(root.stateData, wsid) }   // "" == Off
  // The layout to *show* for a workspace — its remembered choice even when off,
  // so the chip icon keeps its shape after you turn Parquet off.
  function displayLayout(wsid) {
    var e = Parquet.workspaceEntry(root.stateData, wsid)
    if (e && e.layout) return e.layout
    var lib = Parquet.libraryList(root.stateData)
    return lib.length ? lib[0].name : ""
  }
  function enabledFor(wsid) {
    var e = Parquet.workspaceEntry(root.stateData, wsid)
    return !!(e && e.enabled)
  }
  function fillFor(wsid) {
    var e = Parquet.workspaceEntry(root.stateData, wsid)
    return e ? e.fill : "dwindle"
  }
  function layoutInUse(name) { return Parquet.layoutInUse(root.stateData, name) }
  function suggestName(tree) { return Parquet.suggestName(root.stateData, tree) }

  // ---- writes --------------------------------------------------------

  // Every write goes: update stateData -> mkdir -> flush to disk -> (onSaved)
  // -> tell the shim to re-read -> re-set the workspace_rule for each affected
  // workspace (that last step is what actually re-tiles: a bare reload updates
  // the shim's state but doesn't recalculate an existing workspace on 0.56.2).
  // `_disableWs` carries a workspace that was just turned off so it can be
  // handed back to its native layout.
  // Editor.save() chains two of these in one tick (create + apply, or rename +
  // save). That coalesces into a single flush of the final stateData, which is
  // what we want — but a caller that passed no `disableWs` must not wipe the one
  // an earlier call in the same burst set. _afterSave / onSaveFailed clear it.
  function _persist(next, disableWs) {
    root.stateData = Parquet.normalizeState(next)
    if (disableWs !== undefined) root._disableWs = disableWs
    root._writing = true
    root._reloadAfterSave = true
    _scheduleFlush()
  }

  // mkdir -p once per session, then write straight through.
  function _scheduleFlush() {
    if (root._dirEnsured) _flush()
    else ensureDirProc.running = true       // _flush happens in onExited
  }

  // Put a workspace back on whatever layout it would have had WITHOUT Parquet.
  // The Lua is built (and tested) in Parquet.js — see restoreNativeLua.
  function _restoreNativeCmd(wsid) {
    return ["hyprctl", "eval", Parquet.restoreNativeLua(wsid)]
  }
  function _flush() {
    stateFile.setText(JSON.stringify(root.stateData, null, 2) + "\n")
  }

  // Write the current (seeded) stateData back — first run, or a pre-v2 file.
  function _seedToDisk() {
    root._writing = true
    root._reloadAfterSave = true
    _scheduleFlush()
  }

  // Runs from onSaved once the new state.json is on disk:
  //   1. tell the shim to re-read it — directly, because hl.dsp.layout("reload")
  //      only reaches the shim when the focused workspace is already lua:parquet
  //   2. re-set each enabled workspace's rule, which forces Hyprland to re-tile
  //      it (a bare reload updates shim state but doesn't recalculate)
  //   3. hand a just-disabled workspace back to its previous native layout
  // Steps 1 and 2 go out as ONE `hyprctl eval`. They used to be one process per
  // enabled workspace, so a save on a machine with several Parquet workspaces
  // spawned five or six hyprctl processes in a row for what is a single Lua
  // statement. Workspace ids are digits-only (normalizeState drops anything
  // else), so building this by concatenation stays safe.
  function _afterSave() {
    var ws = root.stateData.workspaces
    var ids = []
    for (var id in ws) if (ws[id].enabled) ids.push('"' + id + '"')
    queue(["hyprctl", "eval",
           'if _G.parquet then _G.parquet.load_state(); _G.parquet.apply_rules() end'
           + ' for _, w in ipairs({' + ids.join(", ") + '}) do'
           + ' pcall(hl.workspace_rule, { workspace = w, layout = "lua:parquet" }) end'])
    if (root._disableWs >= 0) {
      queue(_restoreNativeCmd(root._disableWs))
      root._disableWs = -1
    }
  }

  // Point a workspace at a library layout and turn Parquet on for it.
  function applyLayout(wsid, name) {
    _persist(Parquet.applyLayout(root.stateData, wsid, name, root.activeWorkspaceLayout))
  }

  // Turn Parquet on for a workspace using whatever layout it last had (or the
  // first library layout). Used by the bar chip's left-click.
  function enableWorkspace(wsid) {
    var e = Parquet.workspaceEntry(root.stateData, wsid)
    var lib = Parquet.libraryList(root.stateData)
    var name = (e && e.layout) ? e.layout : (lib.length ? lib[0].name : "grid 2x2")
    applyLayout(wsid, name)
  }

  // Back to the workspace's previous (native) layout.
  function disableWorkspace(wsid) {
    _persist(Parquet.disableWorkspace(root.stateData, wsid), wsid)
  }

  function setFill(wsid, mode) {
    _persist(Parquet.setWorkspaceFill(root.stateData, wsid, mode))
  }

  // Editor: overwrite a library layout's tree (every workspace on it follows).
  function saveLayout(name, tree) {
    _persist(Parquet.setLayoutTree(root.stateData, name, tree))
  }

  // Editor: add a new named layout. Returns the (deduped) name it got.
  function createLayout(desiredName, tree) {
    var r = Parquet.addLayout(root.stateData, desiredName, tree)
    _persist(r.state)
    return r.name
  }

  function renameLayout(oldName, newName) {
    var r = Parquet.renameLayout(root.stateData, oldName, newName)
    _persist(r.state)
    return r.name
  }

  function deleteLayout(name) {
    _persist(Parquet.deleteLayout(root.stateData, name))
  }

  // ---- hyprctl ------------------------------------------------------

  function reloadLayout() { queue(["hyprctl", "dispatch", 'hl.dsp.layout("reload")']) }

  function queue(cmd) {
    root._pendingCmds.push(cmd)
    _pump()
  }
  function _pump() {
    if (cmdProc.running || !root._pendingCmds.length) return
    cmdProc.command = root._pendingCmds.shift()
    cmdProc.running = true
  }

  function refreshActiveWorkspace() {
    if (!activeWsProc.running) activeWsProc.running = true
  }

  // ---- wiring -----------------------------------------------------

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root._writing) return
      // "keep" = a non-empty file that won't parse (partial read / hand-edit
      // typo): never overwrite it, never blank our state, just wait for the
      // next atomic write. "seed" = also write our normalized copy back.
      var d = Parquet.readStateDecision(text())
      if (d.action === "keep") return
      root.stateData = d.state
      if (d.action === "seed") root._seedToDisk()
    }
    onLoadFailed: {
      root.stateData = Parquet.normalizeState(null)
      root._seedToDisk()
    }
    onFileChanged: reload()
    onSaved: {
      root._writing = false
      // A completed write is the only real proof the state dir exists and is
      // writable, so that's what lets later writes skip the mkdir.
      root._dirEnsured = true
      if (root._reloadAfterSave) {
        root._reloadAfterSave = false
        root._afterSave()            // reload the shim, then re-tile
      }
    }
    onSaveFailed: {
      root._writing = false
      root._reloadAfterSave = false
      root._disableWs = -1
      root._dirEnsured = false       // maybe the dir went away — mkdir again
    }
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    onExited: root._flush()
  }

  Process {
    id: cmdProc
    onExited: root._pump()
  }

  Process {
    id: activeWsProc
    command: ["hyprctl", "activeworkspace", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(String(text || ""))
          if (d && typeof d.id !== "undefined") {
            root.activeWorkspaceId = d.id
            if (d.tiledLayout) root.activeWorkspaceLayout = String(d.tiledLayout)
          }
        } catch (e) {}
      }
    }
  }

  // Read-only probes. printErrors stays off because "not installed yet" is a
  // perfectly normal state for all three, not something to log about.
  FileView {
    id: hyprlandLuaFile
    path: root.hyprDir + "/hyprland.lua"
    watchChanges: true
    printErrors: false
    onLoaded: {
      root._blockPresent = String(text()).indexOf(Parquet.BLOCK_MARK) !== -1
      root._probed()
    }
    onLoadFailed: { root._blockPresent = false; root._probed() }
    onFileChanged: reload()
  }

  FileView {
    id: installedLayoutFile
    path: root.hyprDir + "/parquet.lua"
    watchChanges: true
    printErrors: false
    onLoaded: { root._installedVersion = Parquet.layoutVersion(text()); root._probed() }
    onLoadFailed: { root._installedVersion = ""; root._probed() }
    onFileChanged: reload()
  }

  FileView {
    id: shippedLayoutFile
    path: root.pluginDir.length ? (root.pluginDir + "/layout/parquet.lua") : ""
    printErrors: false
    onLoaded: { root._shippedVersion = Parquet.layoutVersion(text()); root._probed() }
    onLoadFailed: { root._shippedVersion = ""; root._probed() }
  }

  Process {
    id: setupProc
    // Deliberately not started here — runSetup() is the only thing that sets
    // this Process going, and only the setup card's button calls it.
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.setupError = String(text || "").trim()
    }
    onExited: function(code) {
      root.setupRunning = false
      // install.sh refuses loudly rather than guessing (a symlinked config, an
      // unbalanced managed block, a hyprland.conf machine). Keep its own words:
      // they name the file and what to do about it.
      if (code !== 0 && !root.setupError.length)
        root.setupError = "Setup failed (exit " + code + "). "
                        + "Run scripts/install.sh in a terminal to see why."
      root.recheckSetup()
    }
  }

  Component.onCompleted: {
    stateFile.reload()
    refreshActiveWorkspace()
  }
}
