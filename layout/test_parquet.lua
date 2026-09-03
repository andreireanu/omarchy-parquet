-- Runs parquet.lua against a stand-in for Hyprland, so the geometry and the
-- per-workspace bookkeeping can be checked without a compositor.
--
--   cd layout && lua test_parquet.lua
--
-- Fails loudly on overlap, lost windows, or the wrong workspace's layout.

local W, H = 1920, 1080

local registered = {}
hl = { layout = { register = function(name, def) registered[name] = def end } }

local ctx = {}
ctx.area = { x = 0, y = 0, w = W, h = H }

-- Same semantics as Hyprland's own spiral example: take the given fraction
-- from the named side.
function ctx:split(a, side, ratio)
    if side == "left"   then return { x = a.x,                     y = a.y,                     w = a.w * ratio,  h = a.h } end
    if side == "right"  then return { x = a.x + a.w * (1 - ratio), y = a.y,                     w = a.w * ratio,  h = a.h } end
    if side == "top"    then return { x = a.x,                     y = a.y,                     w = a.w,          h = a.h * ratio } end
    if side == "bottom" then return { x = a.x,                     y = a.y + a.h * (1 - ratio), w = a.w,          h = a.h * ratio } end
    error("unknown side: " .. tostring(side))
end

local STATE_PATH = os.tmpname()
local function write_state(text)
    local f = assert(io.open(STATE_PATH, "w"))
    f:write(text)
    f:close()
end

-- A library for the tests: the two seeded presets plus a few extra shapes so
-- 2-, 3- and 4-zone geometry all get exercised.
local LIB = {
    two             = '{"side":"left","ratio":0.5,"first":{},"rest":{}}',
    three           = '{"side":"left","ratio":0.3333333,"first":{},"rest":{"side":"left","ratio":0.5,"first":{},"rest":{}}}',
    mstack          = '{"side":"left","ratio":0.6,"first":{},"rest":{"side":"top","ratio":0.5,"first":{},"rest":{}}}',
    ["grid 2x2"]         = '{"side":"top","ratio":0.5,"first":{"side":"left","ratio":0.5,"first":{},"rest":{}},"rest":{"side":"left","ratio":0.5,"first":{},"rest":{}}}',
    ["2 stack"]          = '{"side":"left","ratio":0.6,"first":{},"rest":{"side":"top","ratio":0.3333333,"first":{},"rest":{"side":"top","ratio":0.5,"first":{},"rest":{}}}}',
}

-- Build a state.json string: `layouts` = LIB plus any extras, `workspaces` = ws.
local function state_json(workspaces, extra_layouts)
    local parts = {}
    for name, tree in pairs(LIB) do
        parts[#parts + 1] = ('%q:{"tree":%s,"builtin":true}'):format(name, tree)
    end
    for name, tree in pairs(extra_layouts or {}) do
        parts[#parts + 1] = ('%q:{"tree":%s}'):format(name, tree)
    end
    local wsparts = {}
    for id, w in pairs(workspaces or {}) do
        wsparts[#wsparts + 1] = ('%q:{"enabled":%s,"layout":%q,"fill":%q}'):format(
            tostring(id), tostring(w.enabled ~= false), w.layout or "two", w.fill or "dwindle")
    end
    return ('{"version":2,"layouts":{%s},"workspaces":{%s}}'):format(
        table.concat(parts, ","), table.concat(wsparts, ","))
end

write_state(state_json({}))

dofile("parquet.lua")
local layout = assert(registered["parquet"], "parquet layout was not registered")
local P = assert(_G.parquet, "parquet debug table missing")
P.state.state_path = STATE_PATH
layout.layout_msg(ctx, "reload")

local PASS, FAIL = 0, 0
local function ok(cond, label)
    if cond then
        PASS = PASS + 1
    else
        FAIL = FAIL + 1
        print("   FAIL: " .. label)
    end
end

local function run(n, wsid)
    local placed = {}
    ctx.targets = {}
    for i = 1, n do
        ctx.targets[i] = {
            window = { workspace = { id = wsid } },
            place = function(_, box) placed[i] = box end,
        }
    end
    layout.recalculate(ctx)
    return placed
end

local function overlaps(a, b)
    return a.x < b.x + b.w - 0.01 and b.x < a.x + a.w - 0.01
       and a.y < b.y + b.h - 0.01 and b.y < a.y + a.h - 0.01
end

local function no_overlaps(placed, n)
    for i = 1, n do
        for j = i + 1, n do
            if placed[i] and placed[j] and overlaps(placed[i], placed[j]) then
                return false, ("windows %d and %d overlap"):format(i, j)
            end
        end
    end
    return true
end

local function all_placed(placed, n)
    for i = 1, n do
        if not placed[i] then return false, ("window %d never placed"):format(i) end
    end
    return true
end

local function coverage(placed, n)
    local total = 0
    for i = 1, n do
        if placed[i] then total = total + placed[i].w * placed[i].h end
    end
    return total / (W * H) * 100
end

local function same_box(a, b)
    return a and b
       and math.abs(a.x - b.x) < 0.5 and math.abs(a.y - b.y) < 0.5
       and math.abs(a.w - b.w) < 0.5 and math.abs(a.h - b.h) < 0.5
end

----------------------------------------------------------------------
print("\n1. Every library layout fills the screen with the expected zone count")
----------------------------------------------------------------------

local LAYOUT_ZONES = {
    two = 2, three = 3, mstack = 3, ["grid 2x2"] = 4, ["2 stack"] = 4,
}

for name, zones in pairs(LAYOUT_ZONES) do
    write_state(state_json({ ["1"] = { enabled = true, layout = name } }))
    layout.layout_msg(ctx, "reload")

    local placed = run(zones, 1)
    ok(select(1, no_overlaps(placed, zones)), name .. ": zones overlap")
    ok(select(1, all_placed(placed, zones)), name .. ": a window was never placed")
    ok(math.abs(coverage(placed, zones) - 100) < 0.5,
       ("%s: %d windows should cover the screen (got %.1f%%)"):format(name, zones, coverage(placed, zones)))

    print(("   %-16s %d zones  ok"):format(name, zones))
end

----------------------------------------------------------------------
print("\n2. Drawn zones never move when the last one overflows")
----------------------------------------------------------------------

for _, fill in ipairs({ "dwindle", "master", "even" }) do
    write_state(state_json({ ["1"] = { enabled = true, layout = "mstack", fill = fill } }))
    layout.layout_msg(ctx, "reload")

    local base = run(3, 1)
    for extra = 1, 4 do
        local more = run(3 + extra, 1)
        ok(same_box(base[1], more[1]), ("fill %s: zone 1 moved (+%d windows)"):format(fill, extra))
        ok(same_box(base[2], more[2]), ("fill %s: zone 2 moved (+%d windows)"):format(fill, extra))
        ok(select(1, no_overlaps(more, 3 + extra)), ("fill %s, %d windows: overlap"):format(fill, 3 + extra))
    end
    print("   fill " .. fill .. ": zones 1-2 fixed, overflow packs into zone 3  ok")
end

-- Each fill mode has to actually arrange the way it is documented, inside the
-- last zone. mstack's zone 3 is the bottom-right quadrant: x >= 60% of W, the
-- lower half of H.
write_state(state_json({ ["1"] = { enabled = true, layout = "mstack", fill = "master" } }))
layout.layout_msg(ctx, "reload")
do
    local m = run(6, 1)          -- 3 zones, so windows 3..6 share zone 3
    -- "one larger window, the rest stacked BESIDE it": the master is left of
    -- every other overflow window, and taller than any one of them.
    for i = 4, 6 do
        ok(m[3].x < m[i].x, ("fill master: window %d should sit right of the master"):format(i))
        ok(m[3].h > m[i].h - 0.5, ("fill master: master should be taller than window %d"):format(i))
    end
    ok(m[3].w > m[4].w, "fill master: master is wider than a stack window")
    ok(select(1, no_overlaps(m, 6)), "fill master: no overlap with 6 windows")
    print("   fill master: master sits beside the stack, not above it  ok")
end

write_state(state_json({ ["1"] = { enabled = true, layout = "mstack", fill = "even" } }))
layout.layout_msg(ctx, "reload")
do
    local e = run(6, 1)
    ok(math.abs(e[3].h - e[4].h) < 0.5 and math.abs(e[4].h - e[5].h) < 0.5
       and math.abs(e[5].h - e[6].h) < 0.5, "fill even: every overflow slice is the same height")
    print("   fill even: equal slices  ok")
end

----------------------------------------------------------------------
print("\n3. Each workspace draws the layout it names")
----------------------------------------------------------------------

write_state(state_json(
    {
        ["2"] = { enabled = true, layout = "two" },
        ["3"] = { enabled = true, layout = "grid 2x2" },
        ["4"] = { enabled = true, layout = "wide-left" },
        ["5"] = { enabled = true, layout = "grid-2x2" },         -- superseded name, must still resolve
        ["10"] = { enabled = true, layout = "main and 2stack" }, -- ditto, -> "2 stack"
    },
    { ["wide-left"] = '{"side":"left","ratio":0.7,"first":{},"rest":{}}' }
))
layout.layout_msg(ctx, "reload")

local ws2 = run(2, 2)
ok(math.abs(ws2[1].w - W / 2) < 0.5, "ws2 two: window 1 half width")

local ws3 = run(4, 3)
ok(select(1, no_overlaps(ws3, 4)), "ws3 grid-2x2: quadrants overlap")
ok(math.abs(coverage(ws3, 4) - 100) < 0.5, "ws3 grid-2x2: should cover the screen")
ok(math.abs(ws3[1].w - W / 2) < 0.5 and math.abs(ws3[1].h - H / 2) < 0.5,
   "ws3 grid-2x2: window 1 is a quarter")

ok(not same_box(ws2[1], ws3[1]), "ws2 and ws3 lay out differently")

local ws4 = run(2, 4)
ok(math.abs(ws4[1].w - W * 0.7) < 0.5, "ws4 custom 'wide-left': window 1 is 70% wide")

-- ws5 names "grid-2x2" (a superseded name); resolve() must remap it to the
-- seeded "grid 2x2" and draw quadrants, not the 2-pane fallback.
local ws5 = run(4, 5)
ok(math.abs(ws5[1].w - W / 2) < 0.5 and math.abs(ws5[1].h - H / 2) < 0.5,
   "ws5 superseded name 'grid-2x2' still resolves to a 2x2 grid")

-- ws10 names "main and 2stack" (renamed to "2 stack"); window 1 must be the
-- 60%-wide main pane, not a fallback half.
local ws10 = run(3, 10)
ok(math.abs(ws10[1].w - W * 0.6) < 0.5 and math.abs(ws10[1].h - H) < 0.5,
   "ws10 superseded name 'main and 2stack' resolves to '2 stack'")

-- Two workspaces on the same custom layout get the same geometry.
write_state(state_json(
    { ["6"] = { enabled = true, layout = "wide-left" }, ["7"] = { enabled = true, layout = "wide-left" } },
    { ["wide-left"] = '{"side":"left","ratio":0.7,"first":{},"rest":{}}' }
))
layout.layout_msg(ctx, "reload")
ok(same_box(run(2, 6)[1], run(2, 7)[1]), "ws6 and ws7 share 'wide-left' -> identical")

-- A workspace with no entry falls back to a simple 2-pane split.
ok(math.abs(run(2, 99)[1].w - W / 2) < 0.5, "unconfigured ws99: falls back to a 2-pane split")

print("   ws2 two, ws3 grid, ws4/6/7 shared custom, ws5/ws10 superseded names, ws99 fallback  ok")

----------------------------------------------------------------------
print("\n4. layout_msg never returns a string; the shim re-reads state.json")
----------------------------------------------------------------------

for _, msg in ipairs({ "reload", "reload please", "use grid-2x2", "junk", "" }) do
    local r = layout.layout_msg(ctx, msg)
    ok(r == true or r == nil, ("layout_msg(%q) returned %s"):format(msg, type(r)))
end

-- `reload` picks up disk changes.
write_state(state_json({ ["8"] = { enabled = true, layout = "three" } }))
layout.layout_msg(ctx, "reload")
ok(math.abs(run(3, 8)[1].w - W / 3) < 0.5, "reload picked up ws8 = three")

-- recalculate() also polls the file itself (no reload needed) — this is what
-- keeps a workspace correct when it's applied from a non-parquet workspace.
-- Nothing is poked here on purpose: the content diff alone has to notice, which
-- is exactly what the self-heal relies on in a live compositor.
write_state(state_json({ ["8"] = { enabled = true, layout = "grid 2x2" } }))
ok(math.abs(run(4, 8)[1].w - W / 2) < 0.5, "recalculate re-read state.json without a reload message")

-- Malformed JSON must not blow up or wipe the working library.
-- (parquet.lua logs one "[parquet] ... json" line to stderr here on purpose.)
write_state('{"layouts": { this is not json')
ok(pcall(function() layout.layout_msg(ctx, "reload") end), "reload on malformed state.json should not error")
ok(math.abs(run(4, 8)[1].w - W / 2) < 0.5, "a bad read keeps the last-good library (ws8 still grid-2x2)")

-- ...and it recovers on its own once the file is good again, with no reload.
write_state(state_json({ ["8"] = { enabled = true, layout = "three" } }))
ok(math.abs(run(3, 8)[1].w - W / 3) < 0.5, "a good write after a bad one is picked up unaided")

----------------------------------------------------------------------
print("\n5. JSON decoder round-trips the tree vocabulary")
----------------------------------------------------------------------

local decoded = P.json_decode('{"side":"top","ratio":0.42,"first":{},"rest":{"side":"left","ratio":0.5,"first":{},"rest":{}}}')
ok(decoded and decoded.side == "top", "decoder: side")
ok(decoded and math.abs(decoded.ratio - 0.42) < 1e-9, "decoder: ratio")
ok(decoded and type(decoded.first) == "table" and next(decoded.first) == nil, "decoder: leaf is empty table")
ok(decoded and decoded.rest and decoded.rest.side == "left", "decoder: nested split")
ok(select(1, P.json_decode('{bad')) == nil, "decoder: malformed input returns nil")

----------------------------------------------------------------------
-- Removing the plugin must not leave workspaces tiled by it
----------------------------------------------------------------------
-- `omarchy plugin remove` deletes only the QML folder. This file and the managed
-- hyprland.lua block stay behind and keep running, so apply_rules has to notice
-- and hand every workspace BACK to its native layout. Skipping the bind is not
-- enough: lua:parquet is still registered here, so a rule set before the removal
-- would go on resolving and the user would keep being tiled by a plugin they
-- deleted, with no bar chip left to turn it off.
print("\n8. plugin removed -> workspaces handed back to their native layout")
do
    local bound = {}
    hl.workspace_rule = function(t) bound[tostring(t.workspace)] = t.layout end
    hl.get_config = function(_) return "master" end

    write_state(state_json({ ["4"] = { enabled = true, layout = "two" } }))
    P.state.last_raw = nil
    P.load_state()

    -- a folder holding a manifest.json = the plugin is installed
    local present = os.tmpname()
    os.remove(present); os.execute("mkdir -p '" .. present .. "'")
    local mf = assert(io.open(present .. "/manifest.json", "w"))
    mf:write("{}"); mf:close()

    P.state.plugin_dir = present
    bound = {}; P.apply_rules()
    ok(bound["4"] == "lua:parquet",
       "plugin installed -> ws4 claimed (got " .. tostring(bound["4"]) .. ")")

    P.state.plugin_dir = present .. "-gone"
    bound = {}; P.apply_rules()
    ok(bound["4"] == "master",
       "plugin removed -> ws4 handed back to general:layout (got " .. tostring(bound["4"]) .. ")")
    ok(bound["4"] ~= "lua:parquet",
       "plugin removed -> ws4 is never left on lua:parquet")

    os.remove(present .. "/manifest.json"); os.execute("rmdir '" .. present .. "'")
end

os.remove(STATE_PATH)

----------------------------------------------------------------------
print(("\n%d passed, %d failed"):format(PASS, FAIL))
if FAIL == 0 then
    print("\nALL CHECKS PASSED")
    os.exit(0)
else
    print("\nTHERE ARE FAILURES")
    os.exit(1)
end
