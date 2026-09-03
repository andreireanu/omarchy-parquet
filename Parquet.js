.pragma library

// Shared tile-tree logic for the Parquet bar widget and editor.
//
// The tree vocabulary is exactly the one layout/parquet.lua consumes:
//   leaf  -> {}
//   split -> { side: "left" | "top", ratio: 0..1, first: <node>, rest: <node> }
// `side` is the side `first` takes; `rest` gets the rest. A "path" is an array
// of "first" / "rest" strings locating a node from the root.
//
// Pure functions only (no Qt types), so layout/test_parquet.js can run this
// under node. Keep the presets in step with layout/parquet.lua.

// Layouts seeded into the library on first run. Keep in step with parquet.lua.
var PRESETS = {
  "grid 2x2": {
    side: "top", ratio: 0.5,
    first: { side: "left", ratio: 0.5, first: {}, rest: {} },
    rest: { side: "left", ratio: 0.5, first: {}, rest: {} }
  },
  "2 stack": {
    side: "left", ratio: 0.6,
    first: {},
    rest: {
      side: "top", ratio: 1 / 3,
      first: {},
      rest: { side: "top", ratio: 0.5, first: {}, rest: {} }
    }
  },
  // Four columns of unequal heights — the shape the plugin is named after, and
  // the one on the brand mark. Seven zones.
  "parquet": {
    side: "left", ratio: 0.5,
    first: {
      side: "left", ratio: 0.5,
      first: { side: "top", ratio: 0.25, first: {}, rest: {} },
      rest: { side: "top", ratio: 1 / 3, first: {}, rest: {} }
    },
    rest: {
      side: "left", ratio: 0.5,
      first: { side: "top", ratio: 0.4, first: {}, rest: {} },
      rest: {}
    }
  }
};

var PRESET_NAMES = ["grid 2x2", "2 stack", "parquet"];

// Superseded preset names -> current ones. normalizeState (and parquet.lua)
// remap these so a pre-existing state.json follows the rename automatically.
var LEGACY_NAMES = {
  "grid-2x2": "grid 2x2",
  "main-and-2stack": "2 stack",
  "main and 2stack": "2 stack"
};
function canonName(name) {
  return (name && LEGACY_NAMES[name]) ? LEGACY_NAMES[name] : name;
}

// Last-ditch tree when a workspace names a layout that no longer exists and the
// library is somehow empty. Not a named layout.
var FALLBACK_TREE = { side: "left", ratio: 0.5, first: {}, rest: {} };

// The lopsided layout used as the static brand mark (assets/icon.svg draws the
// same shape). Not a preset — just something recognisably hand-drawn.
var BRAND_TREE = {
  side: "left", ratio: 0.62,
  first: {
    side: "top", ratio: 0.55,
    first: {},
    rest: { side: "left", ratio: 0.45, first: {}, rest: {} }
  },
  rest: {
    side: "top", ratio: 0.30,
    first: {},
    rest: { side: "top", ratio: 0.60, first: {}, rest: {} }
  }
};

function isLeaf(node) {
  return !node || (node.first === undefined && node.rest === undefined);
}

function clone(node) {
  if (isLeaf(node)) return {};
  return {
    side: node.side === "top" ? "top" : "left",
    ratio: clampRatio(node.ratio),
    first: clone(node.first),
    rest: clone(node.rest)
  };
}

function presetTree(name) {
  return clone(PRESETS[name] || PRESETS[PRESET_NAMES[0]] || FALLBACK_TREE);
}

function clampRatio(r) {
  r = Number(r);
  if (!isFinite(r)) return 0.5;
  return Math.max(0.05, Math.min(0.95, r));
}

// Snap a dragged ratio to nice fractions, then to a 5% grid.
function snapRatio(r) {
  var nice = [1 / 3, 0.5, 2 / 3];
  for (var i = 0; i < nice.length; i++) {
    if (Math.abs(r - nice[i]) < 0.025) return nice[i];
  }
  return clampRatio(Math.round(r / 0.05) * 0.05);
}

function nodeAt(tree, path) {
  var n = tree;
  for (var i = 0; i < path.length; i++) n = n[path[i]];
  return n;
}

// One rect per leaf (a zone), in window-assignment order.
// Each entry: { x, y, w, h, path, index }.
function leafRects(tree, x, y, w, h) {
  var out = [];
  _leafWalk(tree, x, y, w, h, [], out);
  for (var i = 0; i < out.length; i++) out[i].index = i;
  return out;
}

function _leafWalk(node, x, y, w, h, path, out) {
  if (isLeaf(node)) {
    out.push({ x: x, y: y, w: w, h: h, path: path.slice() });
    return;
  }
  var r = node.ratio;
  if (node.side === "top") {
    _leafWalk(node.first, x, y, w, h * r, path.concat("first"), out);
    _leafWalk(node.rest, x, y + h * r, w, h * (1 - r), path.concat("rest"), out);
  } else {
    _leafWalk(node.first, x, y, w * r, h, path.concat("first"), out);
    _leafWalk(node.rest, x + w * r, y, w * (1 - r), h, path.concat("rest"), out);
  }
}

// One entry per split node, for drawing / dragging dividers.
// Each entry: { path, side, ratio, x, y, w, h } where x/y/w/h is the split
// node's own area (not the divider line).
function splitNodes(tree, x, y, w, h) {
  var out = [];
  _splitWalk(tree, x, y, w, h, [], out);
  return out;
}

function _splitWalk(node, x, y, w, h, path, out) {
  if (isLeaf(node)) return;
  out.push({ path: path.slice(), side: node.side, ratio: node.ratio, x: x, y: y, w: w, h: h });
  var r = node.ratio;
  if (node.side === "top") {
    _splitWalk(node.first, x, y, w, h * r, path.concat("first"), out);
    _splitWalk(node.rest, x, y + h * r, w, h * (1 - r), path.concat("rest"), out);
  } else {
    _splitWalk(node.first, x, y, w * r, h, path.concat("first"), out);
    _splitWalk(node.rest, x + w * r, y, w * (1 - r), h, path.concat("rest"), out);
  }
}

function zoneCount(tree) {
  return leafRects(tree, 0, 0, 1, 1).length;
}

// Split the leaf at `path` in two. `side` is "left" (side-by-side) or "top"
// (stacked); omit it to split along the zone's longer axis given w/h.
function splitLeaf(tree, path, side, w, h) {
  if (!side) side = (w >= h) ? "left" : "top";
  var fresh = { side: side, ratio: 0.5, first: {}, rest: {} };
  if (path.length === 0) return fresh;
  var t = clone(tree);
  var parent = t;
  for (var i = 0; i < path.length - 1; i++) parent = parent[path[i]];
  parent[path[path.length - 1]] = fresh;
  return t;
}

// Merge the leaf at `path` back into its sibling: the parent split is replaced
// by whatever the sibling subtree is. Merging the root leaf is a no-op.
function mergeLeaf(tree, path) {
  if (path.length === 0) return clone(tree);
  var siblingKey = path[path.length - 1] === "first" ? "rest" : "first";
  var siblingPath = path.slice(0, -1).concat(siblingKey);
  var sibling = clone(nodeAt(tree, siblingPath));
  if (path.length === 1) return sibling;
  var t = clone(tree);
  var grandparent = t;
  for (var i = 0; i < path.length - 2; i++) grandparent = grandparent[path[i]];
  grandparent[path[path.length - 2]] = sibling;
  return t;
}

function setRatio(tree, splitPath, ratio) {
  var t = clone(tree);
  var n = t;
  for (var i = 0; i < splitPath.length; i++) n = n[splitPath[i]];
  n.ratio = clampRatio(ratio);
  return t;
}

// True when two paths point at the same node.
function samePath(a, b) {
  if (!a || !b || a.length !== b.length) return false;
  for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// ---- state.json (v2) -------------------------------------------------------
//
// {
//   "version": 2,
//   "layouts": { "<name>": { "tree": <node>, "builtin": <bool> }, ... },
//   "order":   [ "<name>", ... ],                     // display order
//   "workspaces": {
//     "<id>": { "enabled": <bool>, "layout": "<name>",
//               "fill": "dwindle"|"master"|"even", "previousLayout": "<mode>" }
//   }
// }
//
// The presets are seeded into `layouts` on first run; after that state.json is
// the whole library — including which presets are still in it. A workspace just
// names a layout — edit that layout once and every workspace on it follows.

var STATE_VERSION = 2;
var FILL_MODES = ["dwindle", "master", "even"];
var OFF = "";   // the "Off / native" pseudo-layout id used by the picker

function fillMode(v) { return FILL_MODES.indexOf(v) !== -1 ? v : "dwindle"; }

function emptyState() {
  return { version: STATE_VERSION, layouts: {}, order: [], workspaces: {} };
}

// Layout names are typed by hand in the editor and then travel through
// state.json keys, `hyprctl eval` Lua, and the single-quoted JSON the bar widget
// hands to `omarchy-shell shell summon`. An apostrophe alone would end that
// quote, so names are held to an allowlist: letters, digits, spaces and
// . _ + - . Runs of anything else collapse to a space; a leading dot or dash is
// dropped so a name can never read as `..` or a hidden file.
var NAME_MAX = 48;
function sanitizeName(desired) {
  // The two strips run last, over a class that includes spaces, so collapsing
  // "../.." down to ". ." can't leave a fresh leading dot behind.
  var s = String(desired === undefined || desired === null ? "" : desired)
    .replace(/[^A-Za-z0-9 ._+-]+/g, " ")
    .replace(/\.{2,}/g, ".")            // never a ".." anywhere in the name
    .replace(/\s+/g, " ")
    .replace(/^[\s.-]+/, "")            // nor a leading dot / dash
    .replace(/[\s.-]+$/, "");
  // Cap the length. A name is a state.json key, a word in generated Lua, and a
  // label in the picker and the editor; there was no limit at all, so a
  // paragraph pasted into the name field became the layout's name. Trim back to
  // a word boundary when there is one nearby, so the cut reads deliberately.
  if (s.length > NAME_MAX) {
    s = s.slice(0, NAME_MAX);
    var sp = s.lastIndexOf(" ");
    if (sp >= NAME_MAX - 12) s = s.slice(0, sp);
    s = s.replace(/[\s.-]+$/, "");
  }
  return s.length ? s : "layout";
}

// A unique, safe layout name derived from `desired`.
function uniqueLayoutName(state, desired) {
  var base = sanitizeName(desired);
  if (!state.layouts[base]) return base;
  for (var i = 2; i < 999; i++) if (!state.layouts[base + " " + i]) return base + " " + i;
  return base + " " + Date.now();
}

function _seedPresets(s) {
  for (var i = 0; i < PRESET_NAMES.length; i++) {
    var pn = PRESET_NAMES[i];
    if (!s.layouts[pn]) s.layouts[pn] = { tree: presetTree(pn), builtin: true };
  }
}

// Fill in missing/broken bits, and seed the presets into a state that has never
// carried a library.
function normalizeState(raw) {
  var s = emptyState();
  var r = (raw && typeof raw === "object") ? raw : {};

  // Once `layouts` exists it IS the library, whatever is left in it. Seeding a
  // preset back in here would resurrect one the user deleted, because every
  // write passes through normalizeState on its way to disk.
  var hadLibrary = !!(r.layouts && typeof r.layouts === "object");

  if (hadLibrary) {
    for (var name in r.layouts) {
      var L = r.layouts[name];
      if (!L || typeof L !== "object") continue;
      var cn = canonName(name);                 // grid-2x2 -> grid 2x2
      if (cn !== name && r.layouts[cn]) continue; // the new name already exists
      s.layouts[cn] = {
        tree: (L.tree === undefined || L.tree === null) ? {} : clone(L.tree),
        builtin: L.builtin === true || cn !== name
      };
    }
  } else {
    _seedPresets(s);
  }

  // order: keep the file's order for names that still exist, then any preset
  // and any leftover custom layout the file didn't list. Only names actually in
  // the library get in — a dead one would poison order[0].
  var seen = {}, j, k, nm;
  if (Array.isArray(r.order)) {
    for (j = 0; j < r.order.length; j++) {
      var on = canonName(r.order[j]);
      if (s.layouts[on] && !seen[on]) { s.order.push(on); seen[on] = true; }
    }
  }
  for (k = 0; k < PRESET_NAMES.length; k++)
    if (s.layouts[PRESET_NAMES[k]] && !seen[PRESET_NAMES[k]]) {
      s.order.push(PRESET_NAMES[k]); seen[PRESET_NAMES[k]] = true;
    }
  for (nm in s.layouts)
    if (!seen[nm]) { s.order.push(nm); seen[nm] = true; }

  // A library emptied by hand leaves nothing at all to draw — reseed then.
  if (s.order.length === 0) {
    _seedPresets(s);
    for (k = 0; k < PRESET_NAMES.length; k++) s.order.push(PRESET_NAMES[k]);
  }

  if (r.workspaces && typeof r.workspaces === "object") {
    for (var key in r.workspaces) {
      var w = r.workspaces[key];
      if (!w || typeof w !== "object") continue;
      // Numeric ids only (v1 scope: no named or special workspaces). This also
      // keeps a hand-edited key out of the Lua that Service._afterSave builds
      // by string concatenation for `hyprctl eval`.
      if (!/^\d+$/.test(String(key))) continue;
      var layoutName = canonName(typeof w.layout === "string" ? w.layout : "");
      if (!s.layouts[layoutName]) layoutName = s.order[0] || PRESET_NAMES[0];
      s.workspaces[String(key)] = {
        enabled: w.enabled === true,
        layout: layoutName,
        fill: fillMode(w.fill),
        previousLayout: typeof w.previousLayout === "string" ? w.previousLayout : "dwindle"
      };
    }
  }

  return s;
}

// True when `raw` is already a current v2 state, so the widget needn't rewrite
// it. WHICH layouts the library holds is the user's business — a deleted preset
// must not read as "unseeded", or every load would write the preset back. Only
// a missing/old version, a missing library, or names left over from before the
// rename earn a rewrite.
function isSeeded(raw) {
  if (!raw || typeof raw !== "object") return false;
  if (raw.version !== STATE_VERSION) return false;
  if (!raw.layouts || typeof raw.layouts !== "object") return false;
  for (var legacy in LEGACY_NAMES) {
    if (raw.layouts[legacy]) return false;
  }
  if (Array.isArray(raw.order))
    for (var i = 0; i < raw.order.length; i++)
      if (LEGACY_NAMES[raw.order[i]]) return false;
  if (raw.workspaces && typeof raw.workspaces === "object")
    for (var key in raw.workspaces) {
      var w = raw.workspaces[key];
      if (w && typeof w === "object" && LEGACY_NAMES[w.layout]) return false;
    }
  return true;
}

// What Service.qml should do with the text it just read from state.json.
// Returns one of:
//   { action: "keep" }               non-empty but unparseable — a partial read
//                                    or a hand-edit typo; leave our state alone
//   { action: "adopt", state: <s> }  parsed and already seeded — just take it
//   { action: "seed",  state: <s> }  empty/missing, or parsed but not seeded —
//                                    take the normalized state AND write it back
function readStateDecision(raw) {
  var parsed = null, parsedOk = true;
  try { parsed = JSON.parse(raw); } catch (e) { parsedOk = false; }
  // A parse FAILURE on non-empty text is a partial read or a hand-edit typo.
  if (!parsedOk && raw && String(raw).trim().length > 0)
    return { action: "keep" };
  var s = normalizeState(parsed);
  return (parsed === null || parsed === undefined || !isSeeded(parsed))
    ? { action: "seed", state: s }
    : { action: "adopt", state: s };
}

// ---- library ----

function libraryList(state) {
  var out = [];
  for (var i = 0; i < state.order.length; i++) {
    var name = state.order[i];
    var L = state.layouts[name];
    if (L) out.push({ name: name, tree: L.tree, builtin: L.builtin === true });
  }
  return out;
}

// The tree a layout name resolves to, for drawing and for editing.
//
// A leaf ({}) is a legitimate ONE-ZONE layout — merging a two-zone layout down
// to one is two clicks in the editor, and parquet.lua honours it: the single
// zone takes the whole screen and the overflow fill carries on inside it. So a
// stored leaf must come back as stored. This used to reject it along with a
// genuinely broken entry, which made the bar chip and the editor draw the FIRST
// library layout instead — and re-saving from the editor then overwrote the
// user's one-zone layout with that one. Only a name the library doesn't hold
// (or an entry whose tree went missing) falls through.
function layoutTree(state, name) {
  var L = state.layouts[name];
  if (L && L.tree && typeof L.tree === "object") return L.tree;
  var first = state.order && state.order[0];
  var F = first && state.layouts[first];
  return (F && F.tree && typeof F.tree === "object") ? F.tree : clone(FALLBACK_TREE);
}

function addLayout(state, desiredName, tree) {
  var s = normalizeState(state);
  var name = uniqueLayoutName(s, desiredName);
  s.layouts[name] = { tree: clone(tree), builtin: false };
  s.order.push(name);
  return { state: s, name: name };
}

// A starting-point name for a new layout: "<n> zones", deduped.
function suggestName(state, tree) {
  var n = zoneCount(tree);
  return uniqueLayoutName(state, n <= 1 ? "layout" : (n + " zones"));
}

function setLayoutTree(state, name, tree) {
  var s = normalizeState(state);
  if (!s.layouts[name]) { s.layouts[name] = { builtin: false }; s.order.push(name); }
  s.layouts[name].tree = clone(tree);
  return s;
}

function renameLayout(state, oldName, desiredName) {
  var s = normalizeState(state);
  // Compare against the sanitized form, or retyping "my  layout" over the name
  // field of "my layout" would dedupe itself into "my layout 2".
  var wanted = sanitizeName(desiredName);
  if (!s.layouts[oldName] || oldName === wanted) return { state: s, name: oldName };
  var name = uniqueLayoutName(s, wanted);
  s.layouts[name] = s.layouts[oldName];
  delete s.layouts[oldName];
  for (var i = 0; i < s.order.length; i++) if (s.order[i] === oldName) s.order[i] = name;
  for (var key in s.workspaces)
    if (s.workspaces[key].layout === oldName) s.workspaces[key].layout = name;
  return { state: s, name: name };
}

function layoutInUse(state, name) {
  var ids = [];
  for (var key in state.workspaces)
    if (state.workspaces[key].enabled && state.workspaces[key].layout === name) ids.push(key);
  return ids;
}

function deleteLayout(state, name) {
  var s = normalizeState(state);
  if (!s.layouts[name] || s.order.length <= 1) return s;
  delete s.layouts[name];
  s.order = s.order.filter(function (n) { return n !== name; });
  var fallback = s.order[0];
  for (var key in s.workspaces)
    if (s.workspaces[key].layout === name) s.workspaces[key].layout = fallback;
  return s;
}

// ---- workspaces ----

function workspaceEntry(state, wsid) {
  return state.workspaces[String(wsid)] || null;
}

function currentLayout(state, wsid) {
  var e = workspaceEntry(state, wsid);
  return (e && e.enabled) ? e.layout : OFF;
}

// Point a workspace at a library layout and turn Parquet on for it.
// `previousLayout` is the workspace's live Hyprland layout, captured ONLY on the
// off -> on transition: switching between two Parquet layouts would otherwise
// record "parquet" as the layout to go back to.
function applyLayout(state, wsid, name, previousLayout) {
  var s = normalizeState(state);
  if (!s.layouts[name]) name = s.order[0] || PRESET_NAMES[0];
  var key = String(wsid);
  var cur = s.workspaces[key];
  var prev;
  if (cur && cur.enabled) {
    prev = cur.previousLayout;                       // already on — keep it
  } else if (previousLayout && previousLayout !== "lua:parquet"
             && previousLayout !== "parquet") {
    prev = previousLayout;
  } else {
    prev = cur ? cur.previousLayout : "dwindle";
  }
  s.workspaces[key] = {
    enabled: true,
    layout: name,
    fill: cur ? cur.fill : "dwindle",
    previousLayout: prev
  };
  return s;
}

function disableWorkspace(state, wsid) {
  var s = normalizeState(state);
  var e = s.workspaces[String(wsid)];
  if (e) e.enabled = false;
  return s;
}

function setWorkspaceFill(state, wsid, fill) {
  var s = normalizeState(state);
  var e = s.workspaces[String(wsid)];
  if (e) e.fill = fillMode(fill);
  return s;
}

// ---- hyprland glue --------------------------------------------------------

// Lua source for `hyprctl eval` that puts a workspace back on whatever layout it
// would have had WITHOUT Parquet: Omarchy's own per-workspace file if there is
// one, otherwise the global `general:layout`. Beats trusting a stored value.
// Kept here (not inline in Service.qml) so the test can check it stays valid Lua.
function restoreNativeLua(wsid) {
  var ws = String(wsid);
  return 'do local ws = "' + ws + '"'
    + ' local f = os.getenv("HOME") .. "/.local/state/omarchy/workspace-layouts/" .. ws .. ".lua"'
    + ' local ok, chunk = pcall(loadfile, f)'
    + ' if ok and type(chunk) == "function" then pcall(chunk)'
    + ' else local g = (hl.get_config and hl.get_config("general:layout")) or "dwindle"'
    + '   pcall(hl.workspace_rule, { workspace = ws, layout = g }) end end';
}

// Best-effort export for node's test harness; ignored by QML.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    PRESETS: PRESETS, PRESET_NAMES: PRESET_NAMES, BRAND_TREE: BRAND_TREE,
    FALLBACK_TREE: FALLBACK_TREE, FILL_MODES: FILL_MODES, OFF: OFF,
    isLeaf: isLeaf, clone: clone, presetTree: presetTree, clampRatio: clampRatio,
    snapRatio: snapRatio, nodeAt: nodeAt, leafRects: leafRects, splitNodes: splitNodes,
    zoneCount: zoneCount, splitLeaf: splitLeaf, mergeLeaf: mergeLeaf, setRatio: setRatio,
    samePath: samePath,
    LEGACY_NAMES: LEGACY_NAMES, canonName: canonName, sanitizeName: sanitizeName,
    NAME_MAX: NAME_MAX,
    emptyState: emptyState, normalizeState: normalizeState, isSeeded: isSeeded,
    readStateDecision: readStateDecision,
    libraryList: libraryList, layoutTree: layoutTree, addLayout: addLayout,
    setLayoutTree: setLayoutTree, renameLayout: renameLayout, deleteLayout: deleteLayout,
    layoutInUse: layoutInUse, uniqueLayoutName: uniqueLayoutName, suggestName: suggestName,
    workspaceEntry: workspaceEntry, currentLayout: currentLayout, applyLayout: applyLayout,
    disableWorkspace: disableWorkspace, setWorkspaceFill: setWorkspaceFill,
    restoreNativeLua: restoreNativeLua
  };
}
