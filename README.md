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
| `Service.qml` | Shared state file I/O and `hyprctl` calls. Also reads `~/.config/hypr` to tell whether the Lua half is installed, and is the only place that runs the installer - from the setup card's button. |
| `ZoneMark.qml` | Draws a zone tree as a small thumbnail, in the theme colour. |
| `scripts/install.sh` | Puts the Lua half in `~/.config/hypr` and takes it back out. Ships with the plugin; see [What the installer will and will not do](#what-the-installer-will-and-will-not-do). |

`assets/icon.svg` (monochrome, `currentColor`) and `assets/icon-color.svg`
(oak) are the static brand mark; regenerate them with `scripts/gen-icon.sh`.

## Install

```bash
omarchy plugin add https://github.com/andreireanu/omarchy-parquet --enable
```

Then add the bar widget from **Omarchy → Bar → Add widget → Parquet** (or it
lands in the right section automatically on first enable).

The chip will show up dimmed, with **Finish setting up Parquet** in its popup.
That is the second half of the install, and it needs your say-so, because it
writes to your compositor config:

- `~/.config/hypr/parquet.lua` — the tiling layout itself
- one marked block in `~/.config/hypr/hyprland.lua`, which is what registers
  `lua:parquet`; the file is backed up first
- a `hyprctl reload` so Hyprland picks it up

Click **Install the Hyprland layout** and you are done. Nothing else on your
system is touched, and [Uninstalling](#uninstalling) reverses all of it.

<details>
<summary>Why that is a click and not part of the one command</summary>

Parquet is half QML and half a Hyprland Lua layout, and `omarchy plugin add`
only git-clones the QML half — the manifest schema has no install hook. Without
the Lua half there is no `lua:parquet` for a workspace rule to name, so the bar
widget would save your choices and tile nothing.

An earlier version of this plugin closed that gap by running the installer
itself the moment the widget loaded. It should not have: those two files are
*your* compositor config, and editing them is not something adding a bar widget
should imply. So the widget now only **reads** them — to know whether the layout
is installed, and whether it is the version this plugin ships — and the button
is the only thing in Parquet that runs `scripts/install.sh`.

The block has to live in `hyprland.lua` rather than the auto-loaded
`~/.local/state/omarchy/toggles/hypr/`, because Omarchy's own
`workspace-layouts` files load *after* that directory and would override
Parquet's workspace rules on every reload.

To see what the widget sees, from a terminal:

```bash
~/.config/omarchy/plugins/io.github.andreireanu.parquet/scripts/install.sh --status
```

That reads and reports; it writes nothing. If Parquet ever looks dead — the
widget toggles but nothing tiles — check that the layout is registered:

```bash
hyprctl eval 'local f=io.open("/tmp/p","w") f:write(type(_G.parquet)) f:close()'; cat /tmp/p
```

`nil` means the shim is not loaded; `hyprctl reload` puts it back.
</details>

### What the installer will and will not do

`scripts/install.sh` edits the one file it is least allowed to break, so it is
deliberately suspicious. Every managed file is checked before it is touched,
built into a temporary file beside itself, verified, and only then renamed into
place — a rename, so a reload landing mid-install can never see a half-written
config. It **refuses**, having written nothing, when:

- `hyprland.conf` exists and `hyprland.lua` does not. Hyprland prefers the Lua
  file when both are present, so creating one would make it ignore your whole
  `.conf`.
- `hyprland.lua` or `parquet.lua` is a symlink, a directory, or anything other
  than a regular writable file. A rename over a symlink would silently detach a
  dotfiles repo from the config it owns.
- `hyprland.lua` has an unbalanced managed marker — a `>>> parquet` with no
  `<<< parquet`, a stray end marker, or one block nested in another. It cannot
  tell where the block ends, and guessing would truncate the rest of your
  config. It names the line; delete it and run again.
- `HOME` or `XDG_CONFIG_HOME` is relative, empty, `/`, or contains `..`, or it
  is being run as root.

It also pins its own `PATH` rather than trusting the one it inherits, keeps at
most three backups of each managed file, and drops the backups that recorded no
change. `scripts/test_install.sh` exercises every refusal above against a
throwaway `$HOME`.

### From a local checkout

```bash
scripts/install.sh
omarchy-shell shell rescanPlugins    # the script copies files in behind the
                                     # shell's back, so tell it to look again
omarchy plugin enable io.github.andreireanu.parquet
omarchy-restart-shell
```

Without the rescan, `omarchy plugin enable` reports *"plugin is not known"*. The
`omarchy plugin add` route above does this for you. Run this way the script does
both halves at once, so there is no setup card to click.

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
> Editing `layout/parquet.lua` needs `hyprctl reload` instead — and bump its
> `parquet-layout-version:` line, which is how the widget notices an installed
> copy has gone stale.

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

If you do it the other way round, or only ever run `omarchy plugin remove`, you
are still fine: the two Lua files notice the plugin folder is gone and hand every
workspace back to `general:layout`, so nothing keeps tiling. They are just dead
weight until you run the script.

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
                          # idempotent, reversible, never clobbers user config,
                          # and refuses every config it cannot safely rewrite
```

357 checks. `test_install.sh` never touches your real `~/.config`: it overrides
`HOME`, `XDG_CONFIG_HOME` and `XDG_STATE_HOME` together (overriding `HOME`
alone is not a sandbox - `XDG_CONFIG_HOME` wins) and sets `PARQUET_SKIP_RELOAD`
so a test run cannot poke a live session.

## Status

Working end to end on Hyprland 0.56.2 / Omarchy: the layout engine, the shared
tree logic, the bar widget, the picker and the editor. `scripts/test.sh` is
green, and the tiling has been verified on a live compositor - drawn zones hold
their size as windows open, overflow stays inside the last zone, and enabled
workspaces survive `hyprctl reload`.

Installing the Lua half is a click in the widget rather than something that
happens when the plugin loads - see [Install](#install). The bar widget only
ever reads `~/.config/hypr`.

Not yet exercised: more than one monitor, scales other than 1.6, and Hyprland
versions other than 0.56.2 (the Lua layout API is new and still moving).

## License

MIT - see [LICENSE](LICENSE).
