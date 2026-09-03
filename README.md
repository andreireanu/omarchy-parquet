<img src="assets/icon-color.svg" alt="" width="72" align="right">

# Parquet

Fixed tile layouts for [Omarchy](https://omarchy.org/), in the spirit of a
parquet floor: you decide the shapes once, and the windows fit into them.

Draw a set of layouts once, then give one to each workspace from the bar.
Windows land in the tiles you drew and keep that size - opening a second window
does not resize the first. 

## Parts

| File | What it is |
|---|---|
| `layout/parquet.lua` | The tiling layout, registered as `lua:parquet`. Reads the layout library and per-workspace pointers from `~/.local/state/omarchy/parquet/state.json`. |
| `BarWidget.qml` | The bar chip - a live thumbnail of the focused workspace's layout. Click opens the picker. |
| `Panel.qml` / `LayoutCard.qml` | The picker popup: a row of layout tiles (`Off` first), plus Edit / New Layout / Overflow. |
| `Editor.qml` | Fullscreen click-to-split editor (overlay), edits one library layout. |
| `Parquet.js` | Shared logic: the tree vocabulary, split/merge/ratios, and the state.json shape (library + workspaces). |
| `Service.qml` | Shared state file I/O and `hyprctl` calls. |
| `ZoneMark.qml` | Draws a zone tree as a small thumbnail, in the theme colour. |

`assets/icon.svg` (monochrome, `currentColor`) and `assets/icon-color.svg`
(oak) are the static brand mark; regenerate them with `scripts/gen-icon.sh`.

## Install

```bash
omarchy plugin add https://github.com/andreireanu/omarchy-parquet --enable
```

That is the whole install. Then add the bar widget from **Omarchy → Bar → Add
widget → Parquet** (or it lands in the right section automatically on first
enable).

<details>
<summary>What that one command actually has to do</summary>

Parquet is half QML and half a Hyprland Lua layout, and `omarchy plugin add`
only git-clones the QML half - the manifest schema has no install hook. The Lua
half is `~/.config/hypr/parquet.lua` plus a small managed block in
`hyprland.lua`, and it is what registers `lua:parquet`; without it the bar
widget would save your choices and tile nothing.

So the widget puts it there itself: on load it runs
`scripts/install.sh --ensure`, which is a no-op - and reloads nothing - once
everything is current. That also means a half-broken install heals on the next
shell start.

The block has to live in `hyprland.lua` rather than the auto-loaded
`~/.local/state/omarchy/toggles/hypr/`, because Omarchy's own
`workspace-layouts` files load *after* that directory and would override
Parquet's workspace rules on every reload.

If Parquet ever looks dead - the widget toggles but nothing tiles - the layout
is not registered:

```bash
hyprctl eval 'local f=io.open("/tmp/p","w") f:write(type(_G.parquet)) f:close()'; cat /tmp/p
```

`nil` means the shim is not loaded. `omarchy-restart-shell` re-runs the check
and puts it back.
</details>

From a local checkout instead:

```bash
scripts/install.sh
omarchy-shell shell rescanPlugins    # the script copies files in behind the
                                     # shell's back, so tell it to look again
omarchy plugin enable io.github.andreireanu.parquet
omarchy-restart-shell
```

Without the rescan, `omarchy plugin enable` reports *"plugin is not known"*. The
`omarchy plugin add` route above does this for you.

Running `scripts/install.sh` from inside the installed plugin folder is safe: it
detects that its source and its destination are the same directory and skips the
copy step instead of deleting itself.

The plugin folder is **copied**, not symlinked, so editing this repo changes
nothing on a running shell until you re-run `scripts/install.sh`. Re-running it
is cheap and idempotent: files that did not change are not backed up, and only
the three newest backups of each managed file are kept.

> **Changing QML? Restart the shell.** `manifest.json` sets `keepLoaded: true`,
> so the shell keeps this plugin's components alive - including the editor
> overlay - and a hot "Local plugin changed, reloading" does **not** re-read an
> already-instantiated one. `scripts/install.sh && omarchy-restart-shell` is the
> loop; syncing the file alone will have you staring at the previous build.
> Editing `layout/parquet.lua` needs `hyprctl reload` instead.

## Uninstalling

Order matters. `omarchy plugin remove` only deletes the QML folder, so on its
own it leaves the Lua layout and the managed `hyprland.lua` block behind. Run the
script first:

```bash
~/.config/omarchy/plugins/io.github.andreireanu.parquet/scripts/install.sh --uninstall
omarchy plugin remove io.github.andreireanu.parquet
```

The script strips the managed block, removes `~/.config/hypr/parquet.lua` and
every backup it ever made, and puts each workspace back on its native layout. Run
from inside the installed plugin folder it will not delete itself - it says so
and leaves that to `omarchy plugin remove`.

It deliberately **keeps** `~/.local/state/omarchy/parquet/` - that is where your
drawn layouts live, so reinstalling picks them back up. Delete it by hand if you
want them gone too.

From a local checkout, `scripts/install.sh --uninstall` does the same thing and
removes the plugin folder as well.

## Using it

- **Click the bar chip** → the layout picker. Every layout is a tile; the first
  is `Off` (native tiling). Click a tile to give it to the focused workspace and
  turn Parquet on. `Off` restores whatever layout the workspace had before.
- **New Layout** / **Edit Layout** → the fullscreen editor. Click a zone, split
  it (`V` left/right, `H` top/bottom, or double-click to split the long way),
  drag a divider for the ratio, `Del` to merge it back into its neighbour.
  **Save** writes it back - every workspace on that layout follows. Editing
  works whether or not Parquet is on for the current workspace. Merging all the
  way down to a single zone is allowed: that zone gets the whole screen, and
  extra windows arrange themselves inside it with the overflow mode below.
- The editor's **Edit** row lists the whole library - click one to switch to
  editing that layout, name and all. With unsaved changes it asks once before
  discarding them. Saving, renaming and deleting all keep the editor open, so
  you can work through several layouts in one visit; only Cancel, `Esc` and the
  backdrop close it.
- **Overflow** (in the picker) - what the last zone does once it holds more than
  one window:

  | Mode | Behaviour |
  |---|---|
  | `dwindle` | Each new window halves what is left, alternating. Default. |
  | `master` | One larger window, the rest stacked beside it. |
  | `even` | Equal slices. |

Three presets ("grid 2x2", "2 stack", "parquet") are seeded into the library on
first run; edit or delete them like any other, and add your own.

While a workspace has Parquet on, it overrides Omarchy's built-in per-workspace
layout picker for that workspace. Turning it off hands control back.

## Tests

```bash
scripts/test.sh           # everything below, in one shot
```

or individually:

```bash
cd layout
lua test_parquet.lua      # the Lua layout: presets, per-workspace state, overflow
node test_parquet_js.js   # the shared JS: split/merge/ratios, the state.json
                          # read/seed decision, restore-native Lua, and that it
                          # agrees with parquet.lua on preset geometry
cd ..
scripts/test_install.sh   # install.sh round-trip in a throwaway HOME:
                          # idempotent, reversible, never clobbers user config
```

## Status

Working end to end on Hyprland 0.56.2 / Omarchy: the layout engine, the shared
tree logic, the bar widget, the picker and the editor. `scripts/test.sh` is
green, and the tiling has been verified on a live compositor - drawn zones hold
their size as windows open, overflow stays inside the last zone, and enabled
workspaces survive `hyprctl reload`.

Not yet exercised: more than one monitor, scales other than 1.6, and Hyprland
versions other than 0.56.2 (the Lua layout API is new and still moving).

## License

MIT - see [LICENSE](LICENSE).
