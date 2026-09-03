#!/usr/bin/env bash
#
# Install (or uninstall) Parquet's Hyprland half on this machine:
#   - the Lua layout            -> ~/.config/hypr/parquet.lua
#   - a managed require() block -> ~/.config/hypr/hyprland.lua
#   - the shell plugin folder   -> ~/.config/omarchy/plugins/<id>/
#
# NOTHING RUNS THIS FOR YOU. The bar widget only *reads* the first two paths to
# tell whether setup is finished; when it is not it shows a card naming every
# file below, and clicking "Finish setup" there is what runs this script. Adding
# or enabling the plugin never does. See README, "Install".
#
# Idempotent, and careful with the file it is least allowed to break — your live
# compositor config. Every managed file is checked before it is touched (regular
# file, not a symlink, writable, managed markers balanced), built into a
# temporary file beside itself, verified, and only then renamed into place.
# Anything it is not sure about it refuses, with a message, having written
# nothing.
#
# Usage:
#   scripts/install.sh              install / re-sync
#   scripts/install.sh --uninstall  remove everything
#   scripts/install.sh --ensure     install only if the Hyprland half is missing
#                                   or out of date, then reload Hyprland
#   scripts/install.sh --status     say what is installed; writes nothing
#
# Environment:
#   PARQUET_SKIP_RELOAD=1   never call `hyprctl reload` (scripts/test_install.sh
#                           sets this so a test run cannot poke a live session)

set -euo pipefail

# A deterministic environment. This script rewrites the user's compositor
# config, so which `cp`, `awk` or `mv` it gets must not depend on the PATH it
# was invoked with, no shell hook may run inside it, and a hostile IFS must not
# reshape its word splitting.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
unset -v CDPATH GLOBIGNORE BASH_ENV ENV
IFS=$' \t\n'
umask 022

PLUGIN_ID="io.github.andreireanu.parquet"
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

BEGIN_MARK="-- >>> parquet (managed, safe to delete this whole block)"
END_MARK="-- <<< parquet"
STAMP="$(date +%s)"

say()  { printf '  %s\n' "$*"; }
info() { printf '\033[1m%s\033[0m\n' "$*"; }
# First argument is the headline, the rest are indented detail lines.
die() {
  printf 'parquet: %s\n' "${1:-refusing to continue}" >&2
  shift || true
  local line
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  exit 1
}

# ----------------------------------------------------------------------
# Where things go, and why these paths and no others
# ----------------------------------------------------------------------

# Parquet only ever writes under $XDG_CONFIG_HOME and $XDG_STATE_HOME. Validate
# them before deriving anything: a relative, traversing or empty value would
# aim every path below — including the single `rm -rf` — somewhere unintended.
#
# NOTE for anyone hand-testing this script: overriding only HOME is NOT a
# sandbox. Omarchy sets XDG_CONFIG_HOME (to ~/.config), and it wins over HOME
# here, so `HOME=/tmp/whatever scripts/install.sh` still writes to the real
# config. Override XDG_CONFIG_HOME and XDG_STATE_HOME too — scripts/
# test_install.sh does exactly that.
[[ ${EUID:-1000} -ne 0 ]] || die "refusing to run as root." \
  "Parquet installs into your own ~/.config and ~/.local/state." \
  "Run this as the user whose desktop it is."
[[ -n ${HOME:-} && $HOME == /* ]] || die "HOME is unset or not an absolute path."

sane_root() {
  local label="$1" p="$2"
  [[ -n $p ]]                        || die "$label is empty."
  [[ $p == /* ]]                     || die "$label must be an absolute path, got: $p"
  [[ ${p%/} != "" ]]                 || die "$label must not be the filesystem root."
  case "$p" in
    */../*|*/..) die "$label must not contain '..': $p" ;;
  esac
}

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
sane_root "XDG_CONFIG_HOME" "$CONFIG_HOME"
sane_root "XDG_STATE_HOME"  "$STATE_HOME"

HYPR_DIR="$CONFIG_HOME/hypr"
HYPRLAND_LUA="$HYPR_DIR/hyprland.lua"
LAYOUT_DEST="$HYPR_DIR/parquet.lua"
LAYOUT_SRC="$REPO_DIR/layout/parquet.lua"
PLUGINS_DIR="$CONFIG_HOME/omarchy/plugins"
PLUGIN_DEST="$PLUGINS_DIR/$PLUGIN_ID"
STATE_DIR="$STATE_HOME/omarchy/parquet"

# ----------------------------------------------------------------------
# What we are allowed to touch
# ----------------------------------------------------------------------

# A file this script replaces has to be a plain, writable, regular file.
#
# Never a symlink: the managed writes below finish with a rename, which replaces
# the LINK — silently detaching a dotfiles repo from the config it is supposed
# to own — and `cp -p` for the backup would follow the link and copy the wrong
# inode. Never a directory, fifo, socket or device either. Absent is fine; that
# is the case we create.
assert_plain_file() {
  local label="$1" f="$2"
  if [[ -L $f ]]; then
    die "$label is a symlink." \
        "$f -> $(readlink -- "$f" 2>/dev/null || echo '?')" \
        "Parquet replaces this file by renaming over it and will not follow a" \
        "link into someone else's tree. Replace it with a regular file, or add" \
        "the managed block by hand (see README, \"Install\")."
  fi
  if [[ ! -e $f ]]; then return 0; fi
  [[ -f $f ]] || die "$label is not a regular file: $f"
  [[ -w $f ]] || die "$label is not writable: $f"
}

# The directory a managed file lives in: the temp file for the atomic rename is
# created there, so it has to be a real, writable directory.
assert_writable_dir() {
  local d="$1"
  [[ -d $d ]] || die "not a directory: $d"
  [[ -w $d ]] || die "not writable: $d"
}

# Print hyprland.lua (or any file) with the managed block removed. Writes nothing.
#
# The second pass collapses runs of blank lines to one and drops trailing blanks
# entirely, which makes stripping idempotent:
#     strip_file(strip_file(x) + block) == strip_file(x)
# verify_hyprland_lua() relies on exactly that to prove a rewrite changed only
# the block.
strip_file() {
  local f="${1:-$HYPRLAND_LUA}"
  [[ -f $f ]] || return 0
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
  ' "$f" \
  | awk '
    NF { if (pending) print ""; pending = 0; print; next }
    { pending = 1 }
  '
}

# Validate the managed markers BEFORE any rewrite.
#
# strip_file()'s awk starts skipping at a BEGIN marker and only stops at the
# matching END. A hand-edited hyprland.lua carrying a BEGIN with no END would
# therefore strip to EOF — and the rewrite would install that truncation over
# the live config. A stray END, or a BEGIN nested inside a block, is just as
# ambiguous. Refuse and name the line: deleting a stray marker takes two
# seconds, and losing the rest of a compositor config does not.
assert_markers_balanced() {
  [[ -f $HYPRLAND_LUA ]] || return 0
  local msg
  msg="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { if (open) { bad = sprintf("a second begin marker inside a block, at line %d", NR); exit }
              open = NR; next }
    $0 == e { if (!open) { bad = sprintf("an end marker with no begin marker, at line %d", NR); exit }
              open = 0; next }
    END { if (bad != "") print bad
          else if (open) printf "a begin marker at line %d that is never closed\n", open }
  ' "$HYPRLAND_LUA")"
  [[ -z $msg ]] || die \
    "$HYPRLAND_LUA has $msg." \
    "Parquet will not rewrite a config whose managed block it cannot delimit." \
    "Delete the stray marker line and run this again."
}

# Replace $1 with whatever $2 prints, atomically, and only if $3 approves it.
#
#   - mktemp puts the candidate in the destination's OWN directory, so the final
#     rename is a same-filesystem atomic swap: Hyprland reloading mid-install can
#     never observe a half-written config, and the name is not predictable.
#   - the builder's exit status is checked, so a short write — a full disk, a
#     killed awk — is never renamed over a live file.
#   - the verifier is the other half of that guarantee. It is handed the
#     candidate's path and must return 0; verify_hyprland_lua() uses it to prove
#     the new config is the old one with its block swapped for ours and nothing
#     else moved.
#   - the mode of the file being replaced is carried over.
atomic_write() {
  local dest="$1" builder="$2" verifier="${3:-}"
  local dir="${dest%/*}" tmp
  assert_writable_dir "$dir"
  tmp="$(mktemp "$dir/.parquet-write.XXXXXXXX")" \
    || die "could not create a temporary file in $dir"
  if ! "$builder" > "$tmp"; then
    rm -f -- "$tmp"
    die "failed while building $dest — nothing was changed."
  fi
  if [[ -n $verifier ]] && ! "$verifier" "$tmp"; then
    rm -f -- "$tmp"
    die "the new $dest did not pass its own integrity check." \
        "Nothing was changed. Your config is exactly as it was."
  fi
  if [[ -f $dest ]]; then
    chmod --reference="$dest" -- "$tmp" 2>/dev/null || chmod 0644 -- "$tmp"
  else
    chmod 0644 -- "$tmp"
  fi
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; die "could not replace $dest"; }
}

# ----------------------------------------------------------------------
# Backups
# ----------------------------------------------------------------------

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
  [[ -f $f ]] || return 0
  cp -p -- "$f" "$f.parquet-bak.$STAMP"
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
      if (( n > KEEP_BACKUPS )); then rm -f -- "$old"; fi
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
      rm -f -- "$b"       # nothing changed — the backup is noise
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
      rm -f -- "$old"
      n=$((n + 1))
    done
  done
  if (( n )); then say "removed $n leftover backup file(s)"; fi
}

# ----------------------------------------------------------------------
# The managed hyprland.lua block
# ----------------------------------------------------------------------

# Build hyprland.lua holding exactly one managed block.
#
# This used to strip the old block (an mv) and then append the new one (a >>),
# which left the LIVE config with no parquet block in between. Hyprland reloads
# when its config changes, and a reload landing in that window rebuilds the Lua
# state with no `require("parquet")` anywhere in it: `lua:parquet` never gets
# registered, every workspace_rule naming it is silently dropped, and the bar
# widget goes on writing state.json to a layout that no longer exists. Parquet
# then looks completely dead until the next reload. Build the whole file first,
# swap it in once — which is what atomic_write() does with this.
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
emit_hyprland_lua() {
  strip_file "$HYPRLAND_LUA"
  printf '\n%s\n' "$BEGIN_MARK"
  printf 'pcall(require, "parquet")\n'
  printf 'pcall(function() _G.parquet.load_state(); _G.parquet.apply_rules() end)\n'
  printf '%s\n' "$END_MARK"
}

# The candidate must be the old config with its block swapped for ours: one
# marker pair, the require line present, and every other byte where it was.
verify_hyprland_lua() {
  local tmp="$1"
  [[ "$(grep -cxF -- "$BEGIN_MARK" "$tmp" || true)" == "1" ]] || return 1
  [[ "$(grep -cxF -- "$END_MARK"   "$tmp" || true)" == "1" ]] || return 1
  grep -qxF -- 'pcall(require, "parquet")' "$tmp" || return 1
  diff -q <(strip_file "$HYPRLAND_LUA") <(strip_file "$tmp") >/dev/null
}

emit_hyprland_lua_stripped() { strip_file "$HYPRLAND_LUA"; }

# The uninstall candidate must carry no marker at all, and still hold every line
# of the user's own config.
verify_hyprland_lua_stripped() {
  local tmp="$1"
  if grep -qF -- "$BEGIN_MARK" "$tmp"; then return 1; fi
  if grep -qF -- "$END_MARK"   "$tmp"; then return 1; fi
  diff -q <(strip_file "$HYPRLAND_LUA") <(strip_file "$tmp") >/dev/null
}

emit_layout()   { cat -- "$LAYOUT_SRC"; }
verify_layout() { cmp -s "$1" "$LAYOUT_SRC"; }

# ----------------------------------------------------------------------
# Preconditions — everything that can refuse, before anything is written
# ----------------------------------------------------------------------

preflight() {
  # Hyprland uses hyprland.lua in preference to hyprland.conf when both exist
  # ("[cfg] Using lua config found at ..."), so on a .conf-based machine
  # creating a hyprland.lua that holds nothing but our managed block would make
  # Hyprland ignore the user's ENTIRE config on the next reload.
  if [[ ! -f $HYPRLAND_LUA && -f $HYPR_DIR/hyprland.conf ]]; then
    die "refusing to install." \
        "$HYPR_DIR/hyprland.conf exists but hyprland.lua does not." \
        "Hyprland prefers hyprland.lua when both are present, so creating one" \
        "would make it ignore your hyprland.conf completely." \
        "Parquet needs the Lua config Omarchy ships on Hyprland 0.56+."
  fi

  # What we are about to copy has to actually be here.
  [[ -f $LAYOUT_SRC ]] || die \
    "missing $LAYOUT_SRC." \
    "This is not a complete Parquet checkout."
  [[ -f $REPO_DIR/layout/default-state.json ]] || die \
    "missing $REPO_DIR/layout/default-state.json."

  # Both managed targets have to be files we may replace...
  assert_plain_file "$HYPRLAND_LUA" "$HYPRLAND_LUA"
  assert_plain_file "$LAYOUT_DEST"  "$LAYOUT_DEST"
  # ...and hyprland.lua's markers have to be unambiguous.
  assert_markers_balanced
}

# ----------------------------------------------------------------------
# The one rm -rf
# ----------------------------------------------------------------------

# Spell out what the plugin folder is allowed to be before deleting it
# recursively: exactly <config>/omarchy/plugins/<plugin id>, a real directory,
# and not a symlink we would delete through. Returns 1 when there is nothing to
# remove.
plugin_dir_removable() {
  [[ $PLUGIN_DEST == "$PLUGINS_DIR/$PLUGIN_ID" ]] \
    || die "internal: PLUGIN_DEST is not the path it is built from ($PLUGIN_DEST)"
  [[ $PLUGIN_DEST == */omarchy/plugins/"$PLUGIN_ID" ]] \
    || die "internal: unexpected plugin path: $PLUGIN_DEST"
  if [[ -L $PLUGIN_DEST ]]; then
    die "$PLUGIN_DEST is a symlink; Parquet will not delete through it." \
        "Remove it yourself, or use:  omarchy plugin remove $PLUGIN_ID"
  fi
  [[ -d $PLUGIN_DEST ]]
}

# ----------------------------------------------------------------------
# Modes
# ----------------------------------------------------------------------

uninstall_parquet() {
  info "Uninstalling Parquet"

  if [[ -f $HYPRLAND_LUA ]] && grep -qF -- "$BEGIN_MARK" "$HYPRLAND_LUA"; then
    assert_plain_file "$HYPRLAND_LUA" "$HYPRLAND_LUA"
    assert_markers_balanced
    backup "$HYPRLAND_LUA"
    atomic_write "$HYPRLAND_LUA" emit_hyprland_lua_stripped verify_hyprland_lua_stripped
    say "removed the managed block from hyprland.lua"
  fi

  if [[ -e $LAYOUT_DEST || -L $LAYOUT_DEST ]]; then
    assert_plain_file "$LAYOUT_DEST" "$LAYOUT_DEST"
    rm -f -- "$LAYOUT_DEST"
    say "removed $LAYOUT_DEST"
  fi

  if [[ -e $PLUGIN_DEST || -L $PLUGIN_DEST ]]; then
    if [[ $REPO_DIR -ef $PLUGIN_DEST ]]; then
      # We are running from inside the folder we would delete. Do the rest of
      # the uninstall and let the plugin manager remove this one.
      say "not removing $PLUGIN_DEST — this script is running from inside it"
      say "  remove it with:  omarchy plugin remove $PLUGIN_ID"
    elif plugin_dir_removable; then
      rm -rf -- "$PLUGIN_DEST"
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

  # Checked BEFORE anything is written, so a refusal leaves no half-install.
  preflight

  mkdir -p -- "$HYPR_DIR" "$PLUGINS_DIR"
  assert_writable_dir "$HYPR_DIR"

  # 1. the Lua layout
  backup "$LAYOUT_DEST"
  atomic_write "$LAYOUT_DEST" emit_layout verify_layout
  say "layout  -> $LAYOUT_DEST"

  # 2. the managed require() block in hyprland.lua
  if [[ ! -f $HYPRLAND_LUA ]]; then
    say "note: $HYPRLAND_LUA does not exist; creating it"
  fi
  backup "$HYPRLAND_LUA"
  atomic_write "$HYPRLAND_LUA" emit_hyprland_lua verify_hyprland_lua
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
    if plugin_dir_removable; then rm -rf -- "$PLUGIN_DEST"; fi
    mkdir -p -- "$PLUGIN_DEST"
    # copy tracked plugin files only, not the repo scaffolding
    for item in manifest.json LICENSE README.md \
                BarWidget.qml Panel.qml Editor.qml Service.qml \
                LayoutCard.qml ZoneMark.qml Parquet.js \
                layout assets; do
      if [[ -e $REPO_DIR/$item ]]; then cp -r -- "$REPO_DIR/$item" "$PLUGIN_DEST/"; fi
    done
    # install.sh itself ships with the plugin: it is what the setup card's
    # button runs. The rest of scripts/ is repo scaffolding and stays out.
    mkdir -p -- "$PLUGIN_DEST/scripts"
    cp -- "$REPO_DIR/scripts/install.sh" "$PLUGIN_DEST/scripts/install.sh"
    chmod 0755 -- "$PLUGIN_DEST/scripts/install.sh"
    say "plugin  -> $PLUGIN_DEST"
  fi

  mkdir -p -- "$STATE_DIR"
  if [[ ! -f $STATE_DIR/state.json ]]; then
    cp -- "$REPO_DIR/layout/default-state.json" "$STATE_DIR/state.json"
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

# True when the Hyprland half is present and matches this checkout.
hyprland_half_current() {
  [[ -f $LAYOUT_DEST ]] \
  && cmp -s "$LAYOUT_SRC" "$LAYOUT_DEST" \
  && [[ -f $HYPRLAND_LUA ]] \
  && grep -qxF -- "$BEGIN_MARK" "$HYPRLAND_LUA" \
  && grep -qxF -- 'pcall(require, "parquet")' "$HYPRLAND_LUA"
}

# Read-only. Says what the bar widget sees — it reads the same two files
# directly and never shells out to this script. Exit 0 when everything is
# current, 10 when setup is needed.
status_parquet() {
  local need=0
  if [[ -f $LAYOUT_DEST ]] && cmp -s "$LAYOUT_SRC" "$LAYOUT_DEST"; then
    say "layout   $LAYOUT_DEST (current)"
  elif [[ -e $LAYOUT_DEST || -L $LAYOUT_DEST ]]; then
    say "layout   $LAYOUT_DEST (out of date)"; need=1
  else
    say "layout   not installed"; need=1
  fi
  if [[ -f $HYPRLAND_LUA ]] && grep -qxF -- "$BEGIN_MARK" "$HYPRLAND_LUA"; then
    say "config   managed block present in $HYPRLAND_LUA"
  else
    say "config   managed block missing from $HYPRLAND_LUA"; need=1
  fi
  if [[ -d $PLUGIN_DEST ]]; then say "plugin   $PLUGIN_DEST"
  else                           say "plugin   not installed at $PLUGIN_DEST"; fi
  (( need == 0 )) || return 10
}

# Put the Hyprland half in place if it is missing or stale, then reload.
#
# This is what the bar widget's "Finish setup" button runs — after the user has
# read the card naming these files and clicked it. It is deliberately NOT run on
# widget load: `omarchy plugin add` clones the QML half, and the Lua half is a
# separate, consented step.
ensure_parquet() {
  if hyprland_half_current; then return 0; fi

  install_parquet

  # The block is only read at config load, so without this the user would have a
  # widget that does nothing until their next reload or reboot.
  if [[ ${PARQUET_SKIP_RELOAD:-} != 1 ]] && command -v hyprctl >/dev/null 2>&1; then
    hyprctl reload >/dev/null 2>&1 || true
    say "hyprctl reload — lua:parquet is registered"
  fi
}

case "${1:-}" in
  --uninstall|-u) uninstall_parquet ;;
  --ensure)       ensure_parquet ;;
  --status)       status_parquet ;;
  ""|--install)   install_parquet ;;
  -h|--help)      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown option: $1" "Try --help." ;;
esac
