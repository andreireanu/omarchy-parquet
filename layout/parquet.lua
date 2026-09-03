-- Parquet: fixed tile layouts for Hyprland, in the spirit of a parquet floor.
--
-- A layout is a tree of splits, exactly like Tiling Shell's editor produces:
-- every left click there splits a tile, and ctx:split does the same thing here.
-- Leaves are the zones. Window 1 goes in zone 1, window 2 in zone 2, and so on.
--
-- Each workspace has its own tree and its own overflow "fill" mode. The bar
-- widget and the tile editor are the source of truth: they write
--   ~/.local/state/omarchy/parquet/state.json
-- and then send `hl.dsp.layout("reload")`, which makes this shim re-read it.

----------------------------------------------------------------------
-- Split-tree vocabulary
--   leaf  -> { }
--   split -> { side = "left"|"top", ratio = 0..1, first = <node>, rest = <node> }
-- `side` is the side `first` takes; `rest` gets the opposite side.
----------------------------------------------------------------------

-- Layouts seeded into the library on first run (state.json is the real source).
-- Also a fallback for a preset name that isn't in the loaded library yet.
-- Keep in step with PRESETS in Parquet.js.
local PRESETS = {
    ["grid 2x2"] = {
        side = "top", ratio = 0.5,
        first = { side = "left", ratio = 0.5, first = {}, rest = {} },
        rest = { side = "left", ratio = 0.5, first = {}, rest = {} },
    },
    ["2 stack"] = {
        side = "left", ratio = 0.6,
        first = {},
        rest = {
            side = "top", ratio = 1 / 3,
            first = {},
            rest = { side = "top", ratio = 0.5, first = {}, rest = {} },
        },
    },
    -- Four columns of unequal heights — the shape the plugin is named after.
    -- Seven zones. Keep in step with Parquet.js PRESETS.
    ["parquet"] = {
        side = "left", ratio = 0.5,
        first = {
            side = "left", ratio = 0.5,
            first = { side = "top", ratio = 0.25, first = {}, rest = {} },
            rest = { side = "top", ratio = 1 / 3, first = {}, rest = {} },
        },
        rest = {
            side = "left", ratio = 0.5,
            first = { side = "top", ratio = 0.4, first = {}, rest = {} },
            rest = {},
        },
    },
}

-- Superseded names -> current ones, for a state.json written before a rename
-- (the shell rewrites it on next load, but this covers the gap).
local LEGACY_NAMES = {
    ["grid-2x2"] = "grid 2x2",
    ["main-and-2stack"] = "2 stack",
    ["main and 2stack"] = "2 stack",
}

-- Last-ditch tree: a workspace named a layout that no longer exists and the
-- library is empty/broken.
local FALLBACK = { side = "left", ratio = 0.5, first = {}, rest = {} }

----------------------------------------------------------------------
-- Module state: one entry per workspace, loaded from state.json.
----------------------------------------------------------------------

local HOME = os.getenv("HOME") or ""

local M = {
    -- Path is overridable for tests and power users.
    state_path = os.getenv("PARQUET_STATE")
        or (HOME .. "/.local/state/omarchy/parquet/state.json"),
    -- [layout name] = <sanitized tree>       (the library, seeded from state.json)
    layouts = {},
    -- [tostring(workspace id)] = { layout = <name>|nil, fill = <string>|nil,
    --                              enabled = <bool> }
    workspaces = {},
    -- Fallback fill for a workspace with no entry at all.
    default = { fill = "dwindle" },
}

----------------------------------------------------------------------
-- Minimal JSON decoder. Enough for state.json (nested objects, strings,
-- numbers, booleans, null); not a general-purpose parser. Adapted from
-- rxi/json.lua (MIT).
----------------------------------------------------------------------

local function json_decode(str)
    local pos = 1

    local function err(msg)
        error("parquet json: " .. msg .. " at byte " .. pos)
    end

    local function skip_ws()
        local _, e = str:find("^[ \t\r\n]*", pos)
        if e then pos = e + 1 end
    end

    local parse_value

    local escapes = {
        ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
        b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
    }

    local function parse_string()
        pos = pos + 1 -- opening quote
        local buf = {}
        while true do
            local c = str:sub(pos, pos)
            if c == "" then err("unterminated string") end
            if c == '"' then
                pos = pos + 1
                return table.concat(buf)
            elseif c == "\\" then
                local nx = str:sub(pos + 1, pos + 1)
                if nx == "u" then
                    local cp = tonumber(str:sub(pos + 2, pos + 5), 16) or err("bad \\u escape")
                    pos = pos + 6
                    if cp < 0x80 then
                        buf[#buf + 1] = string.char(cp)
                    elseif cp < 0x800 then
                        buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
                    else
                        buf[#buf + 1] = string.char(
                            0xE0 + math.floor(cp / 0x1000),
                            0x80 + math.floor(cp / 0x40) % 0x40,
                            0x80 + cp % 0x40)
                    end
                else
                    buf[#buf + 1] = escapes[nx] or err("bad escape \\" .. nx)
                    pos = pos + 2
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
    end

    local function parse_number()
        local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not s then err("bad number") end
        local num = tonumber(str:sub(s, e)) or err("bad number")
        pos = e + 1
        return num
    end

    local function parse_object()
        pos = pos + 1 -- {
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        while true do
            skip_ws()
            if str:sub(pos, pos) ~= '"' then err("expected object key") end
            local key = parse_string()
            skip_ws()
            if str:sub(pos, pos) ~= ":" then err("expected ':'") end
            pos = pos + 1
            local value = parse_value()
            if value ~= nil then obj[key] = value end
            skip_ws()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "}" then return obj end
            if c ~= "," then err("expected ',' or '}'") end
        end
    end

    local function parse_array()
        pos = pos + 1 -- [
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        while true do
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            pos = pos + 1
            if c == "]" then return arr end
            if c ~= "," then err("expected ',' or ']'") end
        end
    end

    function parse_value()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string() end
        if c == "{" then return parse_object() end
        if c == "[" then return parse_array() end
        if c == "-" or c:match("%d") then return parse_number() end
        if str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
        if str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        if str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
        err("unexpected character '" .. c .. "'")
    end

    local ok, result = pcall(parse_value)
    if not ok then return nil, result end
    return result
end

----------------------------------------------------------------------
-- Loading state
----------------------------------------------------------------------

-- Keep only the tree shape we understand, so a malformed file can never feed
-- garbage into ctx:split.
local function sanitize_tree(node)
    if type(node) ~= "table" then return nil end
    if node.first == nil and node.rest == nil then
        return {} -- leaf
    end
    local side = (node.side == "top") and "top" or "left"
    local ratio = tonumber(node.ratio) or 0.5
    if ratio < 0.05 then ratio = 0.05 end
    if ratio > 0.95 then ratio = 0.95 end
    local first = sanitize_tree(node.first)
    local rest = sanitize_tree(node.rest)
    if not first or not rest then return nil end
    return { side = side, ratio = ratio, first = first, rest = rest }
end

-- Read state.json into fresh tables and only swap them in on full success, so a
-- transient bad read (mid-write) never blanks a working layout.
local function load_state()
    local f = io.open(M.state_path, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if not raw or raw == "" then return end

    local data, decode_err = json_decode(raw)
    if not data then
        io.stderr:write("[parquet] " .. tostring(decode_err) .. "\n")
        return
    end
    if type(data) ~= "table" then return end

    local layouts, workspaces = {}, {}

    if type(data.layouts) == "table" then
        for name, entry in pairs(data.layouts) do
            if type(entry) == "table" then
                layouts[name] = sanitize_tree(entry.tree)
            end
        end
    end

    if type(data.workspaces) == "table" then
        for key, ws in pairs(data.workspaces) do
            if type(ws) == "table" then
                workspaces[tostring(key)] = {
                    layout = type(ws.layout) == "string" and ws.layout or nil,
                    fill = type(ws.fill) == "string" and ws.fill or nil,
                    enabled = ws.enabled == true,
                }
            end
        end
    end

    M.layouts = layouts
    M.workspaces = workspaces
    M.last_raw = raw
end

-- Re-read state.json when its contents change. Called from recalculate() so the
-- shim stays current even when nothing sends it a `reload` (hl.dsp.layout only
-- reaches the *focused* workspace's layout, so applying Parquet to a workspace
-- that's currently on dwindle would otherwise never load that workspace).
--
-- This used to debounce on os.clock(), which counts CPU time, not wall time:
-- 0.05 of it is a huge amount of compositor work, so the guard almost always
-- fired and the self-heal barely ran. The content diff below is the real guard —
-- re-reading a file this small per relayout costs nothing, and only a changed
-- file reaches the parser.
--
-- `M.last_raw` is the last content we LOOKED AT, not the last that parsed. That
-- is deliberate: content which failed to parse is remembered too, so a broken
-- file is not re-parsed (and re-logged) on every single relayout. Nothing is
-- lost by it — any change to the bytes gets another try, so a read caught
-- mid-write heals as soon as the file settles.
local function refresh_state()
    local f = io.open(M.state_path, "r")
    if not f then return end
    local raw = f:read("*a")
    f:close()
    if raw and raw ~= M.last_raw then
        M.last_raw = raw
        pcall(load_state)
    end
end

-- Bind `lua:parquet` to every workspace that state.json marks enabled. Runs at
-- config load (from the managed `require("parquet")`) and again on every
-- `reload` message, so newly enabled workspaces bind without a full
-- `hyprctl reload`. Disabling is the widget's job (it evals a workspace_rule
-- back to the previous layout); this only ever adds.
local function apply_rules()
    if not (hl and type(hl.workspace_rule) == "function") then return end
    for id, ws in pairs(M.workspaces) do
        if ws.enabled then
            pcall(hl.workspace_rule, { workspace = id, layout = "lua:parquet" })
        end
    end
end

----------------------------------------------------------------------
-- Geometry
----------------------------------------------------------------------

-- Walk the tree and collect one box per leaf, in reading order.
local function zones_of(ctx, node, area, out)
    if not node.first then
        out[#out + 1] = area
        return out
    end

    local opposite = { left = "right", top = "bottom" }
    out = zones_of(ctx, node.first, ctx:split(area, node.side, node.ratio), out)
    return zones_of(ctx, node.rest, ctx:split(area, opposite[node.side], 1.0 - node.ratio), out)
end

-- What the last zone does once it holds more than one window. Hyprland cannot
-- lend us its own dwindle or master, so the arrangements are rebuilt here with
-- the same ctx:split the built-in layouts use.
local OPPOSITE = { left = "right", right = "left", top = "bottom", bottom = "top" }

local FILL = {}

-- Each new window halves what is left, alternating direction.
FILL.dwindle = function(ctx, area, targets)
    local rest = area
    for i, target in ipairs(targets) do
        if i == #targets then
            target:place(rest)
        else
            local side = (i % 2 == 1) and "left" or "top"
            target:place(ctx:split(rest, side, 0.5))
            rest = ctx:split(rest, OPPOSITE[side], 0.5)
        end
    end
end

-- One larger window, the others stacked beside it: master takes 60% of the zone
-- on the left, the rest share the column on the right. (This used to split
-- top/bottom at 50/50, which is stacked *below*, not beside, and left the master
-- no bigger than the stack once a few windows arrived.)
FILL.master = function(ctx, area, targets)
    if #targets == 1 then
        targets[1]:place(area)
        return
    end

    local rest = ctx:split(area, "right", 0.4)
    targets[1]:place(ctx:split(area, "left", 0.6))

    for i = 2, #targets do
        if i == #targets then
            targets[i]:place(rest)
        else
            local share = 1.0 / (#targets - i + 1)
            targets[i]:place(ctx:split(rest, "top", share))
            rest = ctx:split(rest, "bottom", 1.0 - share)
        end
    end
end

-- Equal slices, the simplest thing that never overlaps.
FILL.even = function(ctx, area, targets)
    local rest = area
    for i, target in ipairs(targets) do
        if i == #targets then
            target:place(rest)
        else
            local share = 1.0 / (#targets - i + 1)
            target:place(ctx:split(rest, "top", share))
            rest = ctx:split(rest, "bottom", 1.0 - share)
        end
    end
end

----------------------------------------------------------------------
-- Per-workspace resolution
----------------------------------------------------------------------

-- The workspace this recalculation is for, from the first target's window.
-- Returns a string id, or nil when it cannot be determined (e.g. in tests
-- without a window, or a target with no mapped window yet).
local function workspace_of(ctx)
    local t = ctx.targets and ctx.targets[1]
    local w = t and t.window
    local ws = w and w.workspace
    local id = ws and ws.id
    if id == nil then return nil end
    return tostring(id)
end

-- Returns tree, fill for a workspace id (string or nil).
local function resolve(wsid)
    local entry = wsid and M.workspaces[wsid] or nil

    local fill = (entry and entry.fill) or M.default.fill
    if not FILL[fill] then fill = "dwindle" end

    -- The layout this workspace names, from the library; then a preset of the
    -- same name (covers an unseeded state.json); then the fallback.
    local name = entry and entry.layout or nil
    if name and LEGACY_NAMES[name] then name = LEGACY_NAMES[name] end
    local tree = (name and M.layouts[name])
        or (name and PRESETS[name])
        or FALLBACK

    return tree, fill
end

----------------------------------------------------------------------
-- Registration
----------------------------------------------------------------------

hl.layout.register("parquet", {
    recalculate = function(ctx)
        local n = #ctx.targets
        if n == 0 then
            return
        end

        pcall(refresh_state)
        local tree, fill = resolve(workspace_of(ctx))
        local zones = zones_of(ctx, tree, ctx.area, {})
        local k = #zones

        -- Windows fill the zones in order.
        for i, target in ipairs(ctx.targets) do
            if n <= k or i < k then
                target:place(zones[i])
            end
        end

        -- More windows than zones. The last zone stops being a plain box and
        -- starts behaving like a normal Hyprland layout, so extra windows keep
        -- arriving there instead of disturbing the zones the user drew.
        if n > k then
            local overflow = {}
            for i = k, n do
                overflow[#overflow + 1] = ctx.targets[i]
            end
            FILL[fill](ctx, zones[k], overflow)
        end
    end,

    -- `hl.dsp.layout("reload")` re-reads state.json. Note this only reaches the
    -- shim when the *focused* workspace is already on lua:parquet, so it's a
    -- convenience, not the main path — recalculate() polls the file itself, and
    -- the widget also calls _G.parquet.load_state() directly via `hyprctl eval`.
    -- Must return `true`/nil on every path: a returned string becomes a config
    -- error.
    layout_msg = function(ctx, msg)
        if tostring(msg):match("^%s*reload") then
            M.last_raw = nil          -- force a re-read
            pcall(refresh_state)
            pcall(apply_rules)
        end
        return true
    end,
})

-- Load once at startup and bind enabled workspaces. Wrapped so a broken state
-- file never stops the layout from registering.
pcall(load_state)
pcall(apply_rules)

-- Test / debug backdoor. Harmless in production; lets `hyprctl repl` and the
-- unit tests poke at internals.
_G.parquet = {
    load_state = load_state,
    refresh_state = refresh_state,
    apply_rules = apply_rules,
    json_decode = json_decode,
    state = M,
    presets = PRESETS,
    _resolve = resolve,
}
