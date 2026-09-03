// Tests the pure tree logic in ../Parquet.js under node:
//
//   cd layout && node test_parquet_js.js
//
// Parquet.js is a QML shared library (`.pragma library`), so we strip that
// first line and eval the rest here.

const fs = require("fs");
const path = require("path");

const src = fs.readFileSync(path.join(__dirname, "..", "Parquet.js"), "utf8")
  .replace(/^\s*\.pragma\s+library\s*$/m, "");
eval(src); // brings PRESETS, leafRects, splitLeaf, ... into this scope

let pass = 0, fail = 0;
function ok(cond, label) {
  if (cond) { pass++; } else { fail++; console.log("  FAIL: " + label); }
}
function approx(a, b, eps) { return Math.abs(a - b) < (eps || 1e-9); }

// ---- presets -------------------------------------------------------------
console.log("\n1. Presets carve the unit square with the right zone counts");
const expected = { "grid 2x2": 4, "2 stack": 4, "parquet": 7 };
for (const name of PRESET_NAMES) {
  const tree = presetTree(name);
  const rects = leafRects(tree, 0, 0, 1, 1);
  ok(rects.length === expected[name], `${name}: ${rects.length} zones (want ${expected[name]})`);
  let area = 0, overlap = false;
  for (let i = 0; i < rects.length; i++) {
    area += rects[i].w * rects[i].h;
    for (let j = i + 1; j < rects.length; j++) {
      const a = rects[i], b = rects[j];
      if (a.x < b.x + b.w - 1e-6 && b.x < a.x + a.w - 1e-6 &&
          a.y < b.y + b.h - 1e-6 && b.y < a.y + a.h - 1e-6) overlap = true;
    }
  }
  ok(!overlap, `${name}: zones overlap`);
  ok(approx(area, 1, 1e-6), `${name}: zones cover the square (got ${area.toFixed(4)})`);
}

// "grid 2x2" order is TL, TR, BL, BR
{
  const r = leafRects(presetTree("grid 2x2"), 0, 0, 100, 100);
  ok(approx(r[0].x, 0) && approx(r[0].y, 0), "grid 2x2[0] = top-left");
  ok(approx(r[1].x, 50) && approx(r[1].y, 0), "grid 2x2[1] = top-right");
  ok(approx(r[2].x, 0) && approx(r[2].y, 50), "grid 2x2[2] = bottom-left");
  ok(approx(r[3].x, 50) && approx(r[3].y, 50), "grid 2x2[3] = bottom-right");
}

// a state.json written before a preset rename follows the new names
{
  let s = normalizeState({
    version: 2, order: ["grid-2x2", "main-and-2stack", "main and 2stack"],
    layouts: {
      "grid-2x2": { tree: presetTree("grid 2x2"), builtin: true },
      "main-and-2stack": { tree: presetTree("2 stack"), builtin: true }
    },
    workspaces: {
      "5": { enabled: true, layout: "grid-2x2" },
      "6": { enabled: true, layout: "main and 2stack" }
    }
  });
  ok(s.layouts["grid 2x2"] && !s.layouts["grid-2x2"], "migrate: grid-2x2 -> 'grid 2x2'");
  ok(s.layouts["2 stack"] && !s.layouts["main-and-2stack"] && !s.layouts["main and 2stack"],
     "migrate: both old 2-stack spellings -> '2 stack'");
  ok(s.order.indexOf("grid-2x2") === -1 && s.order.indexOf("grid 2x2") !== -1, "migrate: order uses the new name");
  ok(s.workspaces["5"].layout === "grid 2x2", "migrate: workspace repointed (grid)");
  ok(s.workspaces["6"].layout === "2 stack", "migrate: workspace repointed (2 stack)");
  ok(canonName("main and 2stack") === "2 stack" && canonName("parquet") === "parquet",
     "canonName maps a superseded name, passes through the rest");
}

// ---- split / merge round-trips -----------------------------------------
console.log("\n2. splitLeaf / mergeLeaf");
{
  let t = clone(FALLBACK_TREE);                  // a plain 2-pane split
  ok(zoneCount(t) === 2, "2-pane split starts at 2");

  const rects = leafRects(t, 0, 0, 100, 100);
  t = splitLeaf(t, rects[1].path, "top");        // split the right zone
  ok(zoneCount(t) === 3, "split right zone -> 3 zones");

  const r2 = leafRects(t, 0, 0, 100, 100);
  ok(approx(r2[0].w, 50), "left zone untouched by splitting the right one");

  // merge one of the new panes back
  t = mergeLeaf(t, r2[2].path);
  ok(zoneCount(t) === 2, "merge -> back to 2 zones");
  ok(JSON.stringify(clone(t)) === JSON.stringify(clone(FALLBACK_TREE)),
     "merge restored the original 2-pane tree");
}
{
  // splitting the root leaf
  let t = {};
  ok(zoneCount(t) === 1, "empty tree = 1 zone");
  t = splitLeaf(t, [], "left");
  ok(zoneCount(t) === 2, "split root -> 2");
  t = mergeLeaf(t, ["first"]);
  ok(zoneCount(t) === 1, "merge back to root leaf");
  ok(isLeaf(t), "merged root is a leaf");
}
{
  // merging the root leaf is a no-op, never throws
  const t = mergeLeaf({}, []);
  ok(isLeaf(t), "merge root leaf is a safe no-op");
}

// ---- ratios -----------------------------------------------------------
console.log("\n3. setRatio / snapRatio / clampRatio");
{
  let t = clone(FALLBACK_TREE);
  t = setRatio(t, [], 0.7);
  ok(approx(leafRects(t, 0, 0, 100, 100)[0].w, 70), "setRatio 0.7 -> left zone 70%");
  t = setRatio(t, [], 5);
  ok(approx(nodeAt(t, []).ratio, 0.95), "ratio clamps to 0.95");
  t = setRatio(t, [], -1);
  ok(approx(nodeAt(t, []).ratio, 0.05), "ratio clamps to 0.05");
}
ok(approx(snapRatio(0.34), 1 / 3), "snap 0.34 -> 1/3");
ok(approx(snapRatio(0.49), 0.5), "snap 0.49 -> 1/2");
ok(approx(snapRatio(0.66), 2 / 3), "snap 0.66 -> 2/3");
ok(approx(snapRatio(0.22), 0.20), "snap 0.22 -> 0.20 grid");

// ---- splitNodes (dividers) ------------------------------------------
console.log("\n4. splitNodes gives one draggable divider per split");
{
  const t = presetTree("2 stack");  // root split + two nested splits
  const s = splitNodes(t, 0, 0, 1920, 1080);
  ok(s.length === 3, `2 stack has 3 splits (got ${s.length})`);
  ok(s[0].side === "left" && approx(s[0].w, 1920), "root split spans full width");
  ok(s[1].side === "top" && approx(s[1].x, 1920 * 0.6), "nested split sits in the right column");
}

// ---- state.json: library + workspaces -----------------------------
console.log("\n5. state helpers (library model)");
{
  // normalizeState seeds the presets and an order
  let s = normalizeState(null);
  ok(PRESET_NAMES.every(n => s.layouts[n] && s.layouts[n].builtin),
     "normalize seeds every preset as builtin");
  ok(s.order.slice(0, PRESET_NAMES.length).join(",") === PRESET_NAMES.join(","),
     "normalize orders presets first");
  ok(Object.keys(s.workspaces).length === 0, "no workspaces to start");
  ok(isSeeded(s) && !isSeeded(null), "isSeeded true for a seeded state, false for null");

  // apply a preset to a workspace
  s = applyLayout(s, 3, "grid 2x2", "master");
  ok(s.workspaces["3"].enabled === true, "applyLayout turns Parquet on");
  ok(s.workspaces["3"].layout === "grid 2x2", "applyLayout points the workspace at the layout");
  ok(s.workspaces["3"].previousLayout === "master", "applyLayout records previousLayout");
  ok(zoneCount(layoutTree(s, "grid 2x2")) === 4, "layoutTree resolves the preset");

  // add a custom layout, share it between two workspaces
  const base = clone(FALLBACK_TREE);
  const custom = splitLeaf(base, leafRects(base, 0, 0, 1, 1)[1].path, "top");
  ok(suggestName(s, custom) === "3 zones", "suggestName -> '<n> zones'");
  ok(suggestName(s, {}) === "layout", "suggestName for 1 zone -> 'layout'");
  let r = addLayout(s, "3 zones", custom);
  s = r.state;
  ok(suggestName(s, custom) === "3 zones 2", "suggestName dedupes once a '3 zones' exists");
  r = addLayout(s, "my  layout ", custom);
  s = r.state;
  ok(r.name === "my layout", "addLayout collapses whitespace, keeps spaces");
  ok(s.order[s.order.length - 1] === "my layout", "addLayout appends to the order");
  ok(zoneCount(layoutTree(s, "my layout")) === 3, "custom layout stored");

  s = applyLayout(s, 3, "my layout");
  s = applyLayout(s, 7, "my layout");
  ok(layoutInUse(s, "my layout").sort().join(",") === "3,7", "layoutInUse lists both workspaces");

  // A one-zone layout (merge a two-zone layout down to one) must survive the
  // round trip: parquet.lua gives the single zone the whole screen, so the
  // editor and the bar chip have to draw it that way too. layoutTree used to
  // swap in the first library layout here, which also meant re-saving from the
  // editor silently overwrote the user's layout.
  {
    const two = splitLeaf({}, [], "left", 100, 100);
    const one = mergeLeaf(two, leafRects(two, 0, 0, 1, 1)[0].path);
    ok(isLeaf(one), "merging one of two zones leaves a single-zone tree");
    let s1 = setLayoutTree(normalizeState(null), "solo", one);
    ok(isLeaf(layoutTree(s1, "solo")), "layoutTree returns a stored one-zone tree as stored");
    ok(zoneCount(layoutTree(s1, "solo")) === 1, "…and it is one zone, not the first library layout");
    // reopening it in the editor and saving unchanged must not change it
    s1 = setLayoutTree(s1, "solo", layoutTree(s1, "solo"));
    ok(zoneCount(layoutTree(s1, "solo")) === 1, "editor round trip keeps the one-zone layout");
    // it still survives a trip through disk
    const s2 = readStateDecision(JSON.stringify(s1)).state;
    ok(zoneCount(layoutTree(s2, "solo")) === 1, "one-zone layout survives normalizeState");
    // a name that genuinely is not in the library still falls back
    ok(!!layoutTree(s1, "no such layout"), "an unknown name still falls back to something drawable");
    ok(zoneCount(layoutTree(s1, "no such layout")) > 1, "…and the fallback is a real multi-zone layout");
  }

  // editing the shared layout affects both
  s = setLayoutTree(s, "my layout", presetTree("grid 2x2"));
  ok(zoneCount(layoutTree(s, "my layout")) === 4, "setLayoutTree updates the library entry");
  ok(currentLayout(s, 3) === "my layout" && currentLayout(s, 7) === "my layout",
     "both workspaces still on the edited layout");

  // rename repoints the workspaces
  r = renameLayout(s, "my layout", "coding");
  s = r.state;
  ok(r.name === "coding" && !s.layouts["my layout"], "renameLayout moves the entry");
  ok(currentLayout(s, 3) === "coding" && currentLayout(s, 7) === "coding",
     "renameLayout repoints workspaces");

  // dedupe on rename collision
  r = renameLayout(s, "coding", "grid 2x2");
  ok(r.name === "grid 2x2 2", "renameLayout dedupes against an existing name");
  s = r.state;

  // delete falls the workspaces back to the first remaining layout
  s = deleteLayout(s, "grid 2x2 2");
  ok(!s.layouts["grid 2x2 2"], "deleteLayout removes the entry");
  ok(currentLayout(s, 3) === s.order[0], "deleteLayout repoints workspaces to order[0]");

  // off / on
  s = disableWorkspace(s, 3);
  ok(currentLayout(s, 3) === "" && s.workspaces["3"].enabled === false, "disableWorkspace -> Off");
  ok(s.workspaces["3"].layout === s.order[0], "disable keeps the layout name for re-enable");

  s = setWorkspaceFill(s, 7, "even");
  ok(s.workspaces["7"].fill === "even", "setWorkspaceFill");
  s = setWorkspaceFill(s, 7, "nonsense");
  ok(s.workspaces["7"].fill === "dwindle", "setWorkspaceFill rejects junk");
}

// ---- deleting a built-in preset sticks --------------------------------
{
  // Every write runs through normalizeState, so a preset seeded back in there
  // would make built-ins undeletable. They are the user's to remove.
  let s = normalizeState(null);
  ok(s.layouts["grid 2x2"] && s.layouts["grid 2x2"].builtin, "starts with the built-in");
  s = deleteLayout(s, "grid 2x2");
  ok(!s.layouts["grid 2x2"], "deleteLayout drops a built-in preset");
  ok(!normalizeState(s).layouts["grid 2x2"], "normalizeState does not resurrect it");
  ok(!normalizeState(JSON.parse(JSON.stringify(s))).layouts["grid 2x2"],
     "a round-trip through state.json does not resurrect it either");
  ok(s.order.indexOf("grid 2x2") === -1, "and it is gone from the order");

  // ...but the last layout standing is never removed, and an emptied library
  // reseeds rather than leaving nothing to draw. Delete down to one first —
  // how many presets are seeded is PRESET_NAMES' business, not this test's.
  while (s.order.length > 1) s = deleteLayout(s, s.order[0]);
  ok(s.order.length === 1, "deleted down to a single layout");
  const survivor = s.order[0];
  const only = deleteLayout(s, survivor);
  ok(only.layouts[survivor], "deleteLayout refuses to remove the last layout");
  const emptied = normalizeState({ version: 2, layouts: {}, order: [], workspaces: {} });
  ok(PRESET_NAMES.every(n => emptied.layouts[n]), "a hand-emptied library reseeds");
}

// ---- layout names are shell-safe --------------------------------------
{
  // A name reaches `omarchy-shell shell summon ... '<json>'` inside a
  // single-quoted shell word, so a quote in it must never survive.
  ok(sanitizeName("it's mine").indexOf("'") === -1, "apostrophe stripped");
  ok(sanitizeName("'; xmessage pwned; '") === "xmessage pwned", "shell metacharacters stripped");
  ok(/^[A-Za-z0-9 ._+-]+$/.test(sanitizeName('a"b`c$d;e|f&g<h>i(j)k')), "only safe characters survive");
  ok(sanitizeName("../../etc/passwd") === "etc passwd", "no path traversal");
  ok(sanitizeName("trailing-") === "trailing", "trailing dash dropped");

  // Names had no length limit at all, so a pasted paragraph became a layout
  // name — a state.json key, a word in generated Lua, and a label the picker
  // and the editor both have to fit.
  const longName = "a deliberately long layout name that runs past the cap";
  ok(sanitizeName(longName).length <= NAME_MAX, "a long name is capped to NAME_MAX");
  ok(sanitizeName("x".repeat(500)).length === NAME_MAX, "an absurd name is capped exactly");
  ok(sanitizeName(("word ").repeat(60)).length <= NAME_MAX, "a long run of words is capped");
  ok(sanitizeName(longName) === "a deliberately long layout name that runs past",
     "the cap prefers a word boundary over cutting mid-word");
  ok(!/[\s.-]$/.test(sanitizeName(longName)), "a capped name never ends in space/dot/dash");
  ok(sanitizeName("short name") === "short name", "a normal name is untouched by the cap");
  // capping must not break the other guarantees
  ok(/^[A-Za-z0-9 ._+-]+$/.test(sanitizeName("'; rm -rf / ; '".repeat(40))),
     "a long hostile name is still sanitized as well as capped");
  ok(sanitizeName("x".repeat(500)).length > 0, "capping never empties a name");
  ok(sanitizeName("   ") === "layout" && sanitizeName("") === "layout", "blank falls back to 'layout'");
  ok(sanitizeName("-leading") === "leading" && sanitizeName(".hidden") === "hidden",
     "leading dot/dash dropped");
  // the names actually in use are untouched
  for (const n of PRESET_NAMES) ok(sanitizeName(n) === n, `preset name '${n}' survives unchanged`);
  ok(sanitizeName("my  layout ") === "my layout", "whitespace collapses, spaces kept");

  let s = normalizeState(null);
  const r = addLayout(s, "it's a; layout", clone(FALLBACK_TREE));
  ok(r.name.indexOf("'") === -1 && r.name.indexOf(";") === -1, "addLayout stores a safe name");
  ok(r.state.layouts[r.name], "and the library is keyed by that safe name");

  // renaming to a differently-spaced version of the same name is a no-op, not a
  // self-collision that appends " 2"
  let s2 = addLayout(normalizeState(null), "my layout", clone(FALLBACK_TREE)).state;
  ok(renameLayout(s2, "my layout", "my  layout ").name === "my layout",
     "rename to the same sanitized name keeps the name");
}

// ---- previousLayout is captured only on off -> on ---------------------
{
  let s = normalizeState(null);
  s = applyLayout(s, 2, "grid 2x2", "master");
  ok(s.workspaces["2"].previousLayout === "master", "captured on the off -> on transition");
  // switching between Parquet layouts reports the live layout as parquet's own;
  // that must not become the thing we restore to.
  s = applyLayout(s, 2, "2 stack", "lua:parquet");
  ok(s.workspaces["2"].previousLayout === "master", "'lua:parquet' never overwrites it");
  s = applyLayout(s, 2, "grid 2x2", "parquet");
  ok(s.workspaces["2"].previousLayout === "master", "bare 'parquet' never overwrites it either");
  s = applyLayout(s, 2, "grid 2x2", "dwindle");
  ok(s.workspaces["2"].previousLayout === "master", "a live layout while already on is ignored");
  // ...but turning it off and on again re-captures
  s = disableWorkspace(s, 2);
  s = applyLayout(s, 2, "grid 2x2", "scrolling");
  ok(s.workspaces["2"].previousLayout === "scrolling", "re-captured after an off -> on round trip");
}
{
  // normalizeState tolerates garbage and preserves a valid custom layout
  const s = normalizeState({
    version: 2,
    layouts: { "keep": { tree: { side: "left", ratio: 0.5, first: {}, rest: {} } }, "bad": 5 },
    order: ["keep", "ghost", "grid-2x2"],
    workspaces: { "2": { enabled: true, layout: "keep" }, "x": 5, "3": null, "4": { enabled: true, layout: "gone" } }
  });
  ok(s.layouts["keep"] && !s.layouts["bad"], "normalize keeps a valid layout, drops junk");
  ok(s.order.indexOf("keep") !== -1 && s.order.indexOf("ghost") === -1, "normalize drops dead names from order");
  ok(s.workspaces["2"].layout === "keep", "normalize keeps a valid workspace");
  ok(!("x" in s.workspaces) && !("3" in s.workspaces), "normalize drops junk workspaces");
  // a non-numeric id would be concatenated into the Lua Service._afterSave evals
  const inj = normalizeState({
    version: 2, layouts: { "keep": { tree: clone(FALLBACK_TREE) } }, order: ["keep"],
    workspaces: {
      '1", layout = "x': { enabled: true, layout: "keep" },
      "special:magic": { enabled: true, layout: "keep" },
      "-2": { enabled: true, layout: "keep" },
      "6": { enabled: true, layout: "keep" }
    }
  });
  ok(Object.keys(inj.workspaces).join(",") === "6", "only numeric workspace ids survive");
  ok(s.workspaces["4"].layout === s.order[0], "workspace naming a missing layout falls back to order[0]");
  ok(libraryList(s).length === s.order.length, "libraryList matches the order");
}

// ---- the two implementations agree on preset geometry ------------
console.log("\n6. Parquet.js presets match layout/parquet.lua exactly");
{
  const luaSrc = fs.readFileSync(path.join(__dirname, "parquet.lua"), "utf8");
  // pull the PRESETS block and eval it as JS after light massaging
  const block = luaSrc.match(/local PRESETS = (\{[\s\S]*?\n\})\n/);
  ok(!!block, "found the PRESETS table in parquet.lua");
  if (block) {
    let js = block[1]
      .replace(/--[^\n]*/g, "")                       // strip Lua comments
      .replace(/\["([a-z0-9 -]+)"\]\s*=/g, '"$1":')   // ["grid 2x2"] =  ->  "grid 2x2":
      .replace(/(\w+)\s*=/g, '"$1":')                 // side =          ->  "side":
      .replace(/,(\s*[}\]])/g, "$1");                 // trailing commas
    let luaPresets;
    try { luaPresets = eval("(" + js + ")"); } catch (e) { luaPresets = null; }
    ok(!!luaPresets, "parsed parquet.lua PRESETS as JS");
    if (luaPresets) {
      for (const name of PRESET_NAMES) {
        const a = leafRects(presetTree(name), 0, 0, 1920, 1080);
        const b = leafRects(luaPresets[name], 0, 0, 1920, 1080);
        let match = a.length === b.length;
        for (let i = 0; match && i < a.length; i++) {
          match = approx(a[i].x, b[i].x, 0.01) && approx(a[i].y, b[i].y, 0.01) &&
                  approx(a[i].w, b[i].w, 0.01) && approx(a[i].h, b[i].h, 0.01);
        }
        ok(match, `${name}: JS and Lua zone rects match`);
      }
    }
  }
}

// ---- the seeded default-state.json is current --------------------
console.log("\n7. layout/default-state.json is a seeded state and matches Parquet.js");
{
  const disk = JSON.parse(fs.readFileSync(path.join(__dirname, "default-state.json"), "utf8"));
  ok(isSeeded(disk), "default-state.json is seeded");
  const fresh = normalizeState(null);
  ok(JSON.stringify(normalizeState(disk)) === JSON.stringify(fresh),
     "default-state.json normalizes to the same thing as a fresh seed "
     + "(run: node -e '...' > layout/default-state.json to refresh)");
}

// ---- Service.qml glue: readStateDecision -------------------------------
console.log("\n8. readStateDecision (what the widget does with a state.json read)");
{
  // empty / missing file -> seed a fresh library and write it back
  let d = readStateDecision("");
  ok(d.action === "seed" && isSeeded(d.state), "empty file -> seed");
  d = readStateDecision("   \n\t ");
  ok(d.action === "seed", "whitespace-only file -> seed");
  d = readStateDecision(null);
  ok(d.action === "seed", "null text -> seed");
  d = readStateDecision("null");
  ok(d.action === "seed", 'JSON "null" -> seed (treated as missing)');

  // non-empty but unparseable -> KEEP: never clobber a partial read / typo
  d = readStateDecision('{"layouts": { half written');
  ok(d.action === "keep" && !("state" in d), "truncated JSON -> keep (no state)");
  d = readStateDecision("not json at all");
  ok(d.action === "keep", "garbage text -> keep");

  // a preset the user deleted must NOT come back: the file is current, so it is
  // adopted as-is and never rewritten
  d = readStateDecision(JSON.stringify({
    version: 2, order: ["grid 2x2"],
    layouts: { "grid 2x2": { tree: presetTree("grid 2x2"), builtin: true } },
    workspaces: {}
  }));
  ok(d.action === "adopt", "state with a deleted preset -> adopt (not rewritten)");
  ok(!d.state.layouts["2 stack"], "the deleted preset stays deleted");
  ok(d.state.order.join(",") === "grid 2x2", "order holds only what the library has");

  // a pre-v2 file (no version marker) still gets seeded and written back
  d = readStateDecision(JSON.stringify({ workspaces: { "2": { enabled: true } } }));
  ok(d.action === "seed", "pre-v2 state (no version) -> seed");
  ok(PRESET_NAMES.every(n => d.state.layouts[n]), "seeding a pre-v2 state fills the library");

  // a pre-rename state (superseded preset names) -> seed, and it comes back migrated
  d = readStateDecision(JSON.stringify({
    version: 2, order: ["grid-2x2", "main-and-2stack"],
    layouts: {
      "grid-2x2": { tree: presetTree("grid 2x2"), builtin: true },
      "main-and-2stack": { tree: presetTree("2 stack"), builtin: true }
    },
    workspaces: { "5": { enabled: true, layout: "main and 2stack" } }
  }));
  ok(d.action === "seed", "superseded preset names -> seed (rewrite with new names)");
  ok(d.state.layouts["grid 2x2"] && !d.state.layouts["grid-2x2"], "seed decision migrates the names");
  ok(d.state.layouts["2 stack"] && !d.state.layouts["main-and-2stack"], "seed decision migrates '2 stack'");
  ok(d.state.workspaces["5"].layout === "2 stack", "seed decision repoints the workspace to '2 stack'");

  // fully seeded, with a workspace -> ADOPT, untouched
  const good = normalizeState(null);
  good.workspaces["4"] = { enabled: true, layout: "2 stack", fill: "dwindle", previousLayout: "dwindle" };
  d = readStateDecision(JSON.stringify(good));
  ok(d.action === "adopt", "seeded state -> adopt (no rewrite)");
  ok(d.state.workspaces["4"] && d.state.workspaces["4"].layout === "2 stack",
     "adopt keeps the workspace pointer");

  // a seeded state carrying a custom layout -> adopt, custom survives
  const withCustom = normalizeState(null);
  withCustom.layouts["parquet"] = { tree: clone(BRAND_TREE), builtin: false };
  withCustom.order.push("parquet");
  d = readStateDecision(JSON.stringify(withCustom));
  ok(d.action === "adopt" && d.state.layouts["parquet"], "adopt keeps a custom layout");
}

// ---- Service.qml glue: restoreNativeLua --------------------------------
console.log("\n9. restoreNativeLua emits valid Lua that names the workspace");
{
  const lua = restoreNativeLua(3);
  ok(/ws = "3"/.test(lua), "names the workspace id");
  ok(lua.indexOf("workspace-layouts") !== -1, "checks Omarchy's per-workspace file");
  ok(lua.indexOf('hl.get_config') !== -1 && lua.indexOf('general:layout') !== -1,
     "falls back to the global general:layout");
  ok(lua.indexOf("hl.workspace_rule") !== -1, "applies the fallback via hl.workspace_rule");
  // no unescaped quotes that would break `hyprctl eval`
  ok((lua.match(/"/g) || []).length % 2 === 0, "quotes are balanced");
  ok(restoreNativeLua("7").indexOf('ws = "7"') !== -1, "accepts a string wsid");

  // if `lua` is on PATH, prove the emitted source actually compiles
  try {
    const cp = require("child_process");
    cp.execFileSync("lua", ["-e", "assert(load(io.read('*a')))"], { input: lua, stdio: ["pipe", "ignore", "ignore"] });
    ok(true, "emitted Lua compiles (lua -e load)");
  } catch (e) {
    if (e.code === "ENOENT") { pass++; console.log("  (skip: no `lua` on PATH to compile-check)"); }
    else ok(false, "emitted Lua failed to compile: " + e.message);
  }
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail === 0) { console.log("\nALL CHECKS PASSED"); process.exit(0); }
else { console.log("\nTHERE ARE FAILURES"); process.exit(1); }
