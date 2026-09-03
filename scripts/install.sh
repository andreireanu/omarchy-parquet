#!/usr/bin/env bash
#
# Install (or uninstall) Parquet on this machine:
#   - the Lua layout            -> ~/.config/hypr/parquet.lua
#   - a managed require() block -> ~/.config/hypr/hyprland.lua
#   - the shell plugin folder   -> ~/.config/omarchy/plugins/<id>/
#
# Idempotent. Every file it touches is backed up once per run. It does NOT
# enable the plugin or restart the shell — do that yourself:
#
#   omarchy plugin enable io.github.andreireanu.parquet
#   omarchy-restart-shell
#
# Usage:
#   scripts/install.sh              install / re-sync
#   scripts/install.sh --uninstall  remove everything
#   scripts/install.sh --ensure     put the Hyprland half in place if it is not
#                                   already, and reload only if that changed
#                                   something (the bar widget runs this on load)

set -euo pipefail

PLUGIN_ID="io.github.andreireanu.parquet"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# NOTE for anyone hand-testing this script: overriding only HOME is NOT a
# sandbox. Omarchy sets XDG_CONFIG_HOME (to ~/.config), and it wins over HOME
# below, so `HOME=/tmp/whatever scripts/install.sh` still writes to the real
# config. Override XDG_CONFIG_HOME and XDG_STATE_HOME too — scripts/
# test_install.sh does exactly that.
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"
HYPRLAND_LUA="$HYPR_DIR/hyprland.lua"
LAYOUT_DEST="$HYPR_DIR/parquet.lua"
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
PLUGIN_DEST="$PLUGINS_DIR/$PLUGIN_ID"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/parquet"

BEGIN_MARK="-- >>> parquet (managed, safe to delete this whole block)"
END_MARK="-- <<< parquet"
STAMP="$(date +%s)"

say()  { printf '  %s\n' "$*"; }
info() { printf '\033[1m%s\033[0m\n' "$*"; }

# Files this run copied aside, settled at the end by settle_backups().
BACKED_UP=()
# How many old backups of each managed file to keep around.
KEEP_BACKUPS=3

# Copy a file aside before we touch it. The copy is PROVISIONAL: settle_backups()
# throws it away again if the write turned out to be a no-op. Re-running the
# installer on an already-current machine used to leave a fresh pair of backups
# every time — 20 runs meant 40 stale files sitting in ~/.config/hypr.
backup() {
  local f="$1"
  [[ -e $f ]] || return 0
  cp -p "$f" "$f.parquet-bak.$STAMP"
  BACKED_UP+=("$f")
}

# Keep only the newest $KEEP_BACKUPS backups of each managed file.
# Ordered by the stamp in the NAME, not by mtime: backup() uses `cp -p`, so a
# backup carries the source file's timestamp and `ls -t` would sort these by
# when the config was last edited rather than when the copy was taken.
prune_backups() {
  local f old n
  for f in "$HYPRLAND_LUA" "$LAYOUT_DEST"; do
    n=0
    while IFS= read -r old; do
      n=$((n + 1))
      if (( n > KEEP_BACKUPS )); then rm -f "$old"; fi
    done < <(ls -1 "$f".parquet-bak.* 2>/dev/null \
             | awk -F'\\.parquet-bak\\.' '{ print $2 "\t" $0 }' \
             | sort -k1,1nr | cut -f2-)
  done
}

# Run once at the end of an install: drop the backups that recorded no change,
# announce the ones that did, then prune the history.
settle_backups() {
  local f b
  for f in ${BACKED_UP[@]+"${BACKED_UP[@]}"}; do
    b="$f.parquet-bak.$STAMP"
    [[ -e $b ]] || continue
    if [[ -e $f ]] && cmp -s "$b" "$f"; then
      rm -f "$b"          # nothing changed — the backup is noise
    else
      say "backed up $(basename "$f") -> $(basename "$b")"
    fi
  done
  prune_backups
}

# Uninstall: take every backup with us. hyprland.lua is put back to its
# pre-install content by strip_block (which only removes the managed block, so
# hand edits survive), which is what these copies were insurance for.
remove_backups() {
  local f old n=0
  for f in "$HYPRLAND_LUA" "$LAYOUT_DEST"; do
    for old in "$f".parquet-bak.*; do
      [[ -e $old ]] || continue
      rm -f "$old"
      n=$((n + 1))
    done
  done
  if (( n )); then say "removed $n leftover backup file(s)"; fi
}

# Print hyprland.lua with the managed block removed. Writes nothing.
strip_block_to_stdout() {
  [[ -f $HYPRLAND_LUA ]] || return 0
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
  ' "$HYPRLAND_LUA" \
  | awk 'NF { blank = 0 } !NF { blank++ } blank < 2'   # drop the trailing blank
}

# Remove the managed block, in one atomic swap (uninstall path).
strip_block() {
  [[ -f $HYPRLAND_LUA ]] || return 0
  local tmp="$HYPRLAND_LUA.tmp.$STAMP"
  strip_block_to_stdout > "$tmp"
  mv "$tmp" "$HYPRLAND_LUA"
}

# Rewrite hyprland.lua so it holds exactly one managed block — in ONE atomic mv.
#
# This used to strip the old block (an mv) and then append the new one (a >>),
# which left the LIVE config with no parquet block in between. Hyprland reloads
# when its config changes, and a reload landing in that window rebuilds the Lua
# state with no `require("parquet")` anywhere in it: `lua:parquet` never gets
# registered, every workspace_rule naming it is silently dropped, and the bar
# widget goes on writing state.json to a layout that no longer exists. Parquet
# then looks completely dead until the next reload. Build the whole file first,
# swap it in once.
#
# A reload that KEEPS the Lua state returns the cached module from `require`, so
# the body does not re-run — but that is fine: the layout is still registered
# from the first load, and the second line below re-reads state.json and rebinds
# the workspace rules. Forcing a fresh load here (package.loaded.parquet = nil)
# is what you must NOT do: it re-runs hl.layout.register on a name that is still
# registered, and Hyprland reports that as a config error on every reload.
#
# The require is pcall'd because this block lives in the USER'S compositor
# config. If parquet.lua goes missing — a half-finished uninstall, a hand-deleted
# file, `omarchy plugin remove` without the script — a bare require throws at
# config load and Hyprland shows a config-error banner over the whole desktop.
# Failing quietly is right: the bar widget's `--ensure` puts the file back on the
# next shell start.
write_block() {
  local tmp="$HYPRLAND_LUA.tmp.$STAMP"
  {
    strip_block_to_stdout
    printf '\n%s\n' "$BEGIN_MARK"
    printf 'pcall(require, "parquet")\n'
    printf 'pcall(function() _G.parquet.load_state(); _G.parquet.apply_rules() end)\n'
    printf '%s\n' "$END_MARK"
  } > "$tmp"
  mv "$tmp" "$HYPRLAND_LUA"
}

uninstall_parquet() {
  info "Uninstalling Parquet"

  if [[ -f $HYPRLAND_LUA ]] && grep -qF -- "$BEGIN_MARK" "$HYPRLAND_LUA"; then
    backup "$HYPRLAND_LUA"
    strip_block
    say "removed the managed block from hyprland.lua"
  fi

  if [[ -e $LAYOUT_DEST ]]; then
    rm -f "$LAYOUT_DEST"
    say "removed $LAYOUT_DEST"
  fi

  if [[ -e $PLUGIN_DEST ]]; then
    if [[ $REPO_DIR -ef $PLUGIN_DEST ]]; then
      # We are running from inside the folder we would delete. Do the rest of
      # the uninstall and let the plugin manager remove this one.
      say "not removing $PLUGIN_DEST — this script is running from inside it"
      say "  remove it with:  omarchy plugin remove $PLUGIN_ID"
    else
      rm -rf "$PLUGIN_DEST"
      say "removed $PLUGIN_DEST"
    fi
  fi

  remove_backups

  say "left $STATE_DIR in place (your drawn layouts). Delete it by hand if you want."
  echo
  info "Done. Now run:  omarchy plugin disable $PLUGIN_ID  &&  omarchy-restart-shell"
}

install_parquet() {
  info "Installing Parquet from $REPO_DIR"

  # Precondition, checked BEFORE anything is written so a refusal leaves no
  # half-install behind. Hyprland uses hyprland.lua in preference to
  # hyprland.conf when both exist ("[cfg] Using lua config found at ..."), so on
  # a .conf-based machine creating a hyprland.lua that holds nothing but our
  # managed block would make Hyprland ignore the user's ENTIRE config on the
  # next reload. The bar widget runs --ensure unattended, so this refuses rather
  # than guesses.
  if [[ ! -f $HYPRLAND_LUA && -f $HYPR_DIR/hyprland.conf ]]; then
    {
      echo "parquet: refusing to install."
      echo "  $HYPR_DIR/hyprland.conf exists but hyprland.lua does not."
      echo "  Hyprland prefers hyprland.lua when both are present, so creating one"
      echo "  would make it ignore your hyprland.conf completely."
      echo "  Parquet needs the Lua config Omarchy ships on Hyprland 0.56+."
    } >&2
    return 1
  fi

  if command -v omarchy-plugin-validate >/dev/null; then
    omarchy plugin validate "$REPO_DIR" >/dev/null && say "manifest validates"
  fi

  mkdir -p "$HYPR_DIR" "$PLUGINS_DIR"

  # 1. the Lua layout
  backup "$LAYOUT_DEST"
  cp "$REPO_DIR/layout/parquet.lua" "$LAYOUT_DEST"
  chmod 0644 "$LAYOUT_DEST"
  say "layout  -> $LAYOUT_DEST"

  # 2. the managed require() block in hyprland.lua
  if [[ ! -f $HYPRLAND_LUA ]]; then
    say "note: $HYPRLAND_LUA does not exist; creating it"
    : > "$HYPRLAND_LUA"
  fi
  backup "$HYPRLAND_LUA"
  write_block   # strip any older block and add the current one, atomically
  say "hyprland.lua -> added managed require(\"parquet\") block"

  # 3. the shell plugin folder (plain copy; re-run this script to re-sync)
  #
  # `omarchy plugin add <git-url>` git-clones the repo straight into
  # ~/.config/omarchy/plugins/<id>/, so the natural next step — running
  # scripts/install.sh out of that clone — has REPO_DIR and PLUGIN_DEST as the
  # SAME directory. The `rm -rf` below would then delete this script's own
  # source tree (13 files -> 0) and the install would die half-done. The QML is
  # already exactly where it belongs in that case; only steps 1, 2 and 4 have
  # anything left to do.
  if [[ $REPO_DIR -ef $PLUGIN_DEST ]]; then
    say "plugin  -> already in place at $PLUGIN_DEST (running from inside it)"
  else
    rm -rf "$PLUGIN_DEST"
    mkdir -p "$PLUGIN_DEST"
    # copy tracked plugin files only, not the repo scaffolding
    for item in manifest.json LICENSE README.md \
                BarWidget.qml Panel.qml Editor.qml Service.qml \
                LayoutCard.qml ZoneMark.qml Parquet.js \
                layout assets; do
      [[ -e $REPO_DIR/$item ]] && cp -r "$REPO_DIR/$item" "$PLUGIN_DEST/"
    done
    # install.sh itself ships with the plugin — BarWidget.qml runs it with
    # --ensure on load to keep the Hyprland half in place. The rest of scripts/
    # is repo scaffolding and stays out.
    mkdir -p "$PLUGIN_DEST/scripts"
    cp "$REPO_DIR/scripts/install.sh" "$PLUGIN_DEST/scripts/install.sh"
    chmod 0755 "$PLUGIN_DEST/scripts/install.sh"
    say "plugin  -> $PLUGIN_DEST"
  fi

  mkdir -p "$STATE_DIR"
  if [[ ! -f $STATE_DIR/state.json ]]; then
    cp "$REPO_DIR/layout/default-state.json" "$STATE_DIR/state.json"
    say "state   -> $STATE_DIR/state.json (seeded with the built-in presets)"
  else
    say "state   -> $STATE_DIR/state.json (kept)"
  fi

  settle_backups

  echo
  info "Installed. Now run:"
  echo "  omarchy plugin enable $PLUGIN_ID"
  echo "  omarchy-restart-shell"
  echo
  say "then reload Hyprland (hyprctl reload) so it picks up parquet.lua."
}

# Make the Hyprland half true if it is not already, then get out of the way.
#
# This is what turns `omarchy plugin add <url> --enable` into a COMPLETE
# install. The plugin manager only git-clones the QML; `lua:parquet` does not
# exist until parquet.lua and the managed hyprland.lua block are in place, so
# BarWidget.qml runs this on load.
#
# Safe to run on every shell start: when everything is already current it does
# nothing at all, and in particular does NOT reload Hyprland.
ensure_parquet() {
  if [[ -f $LAYOUT_DEST ]] \
     && cmp -s "$REPO_DIR/layout/parquet.lua" "$LAYOUT_DEST" \
     && [[ -f $HYPRLAND_LUA ]] \
     && grep -qF -- "$BEGIN_MARK" "$HYPRLAND_LUA" \
     && grep -qF 'pcall(require, "parquet")' "$HYPRLAND_LUA"; then
    return 0
  fi

  install_parquet
  # The block is only read at config load, so without this the user would have
  # a widget that does nothing until their next reload or reboot.
  if command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
    say "hyprctl reload — lua:parquet is registered"
  fi
}

case "${1:-}" in
  --uninstall|-u) uninstall_parquet ;;
  --ensure)       ensure_parquet ;;
  ""|--install)   install_parquet ;;
  -h|--help)      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
