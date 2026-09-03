#!/usr/bin/env bash
#
# Round-trips scripts/install.sh against a throwaway $HOME so we can prove it:
#   - installs every file where it says it does
#   - is idempotent (re-running never doubles the managed hyprland.lua block)
#   - leaves an existing hyprland.lua's user content untouched
#   - fully reverses on --uninstall (no parquet trace left in hyprland.lua)
#   - keeps a state.json the user has already drawn into
#   - --uninstall on a clean machine is a no-op, not an error
#
#   scripts/test_install.sh
#
# Nothing here touches your real ~/.config — everything is under a temp dir.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_DIR/scripts/install.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/parquet-install-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0 FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf '   FAIL: %s\n' "$1"; }
check() { if eval "$1"; then pass; else fail "$2"; fi; }

# A stub `omarchy` / `omarchy-plugin-validate` so the test never shells out to
# the real thing (install.sh calls it if it is on PATH).
STUB_BIN="$SANDBOX/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/omarchy"
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/omarchy-plugin-validate"
chmod +x "$STUB_BIN/omarchy" "$STUB_BIN/omarchy-plugin-validate"

# Each scenario gets its own clean HOME.
new_home() {
  local h="$SANDBOX/home-$1"
  rm -rf "$h"; mkdir -p "$h"
  echo "$h"
}
run_install() {   # run_install <HOME> [--uninstall]
  local h="$1"; shift
  HOME="$h" \
  XDG_CONFIG_HOME="$h/.config" \
  XDG_STATE_HOME="$h/.local/state" \
  PATH="$STUB_BIN:$PATH" \
    bash "$INSTALL" "$@" >/dev/null 2>&1
}
# drop trailing blank lines only (install.sh's awk pass can add/remove one)
rtrim_blanks() { awk 'NF{last=NR} {l[NR]=$0} END{for(i=1;i<=last;i++) print l[i]}' "$1"; }
mark_count()  { grep -cF -- ">>> parquet" "$1" 2>/dev/null || true; }

CFG=".config/hypr"
PLUG=".config/omarchy/plugins/io.github.andreireanu.parquet"
ST=".local/state/omarchy/parquet/state.json"

# ----------------------------------------------------------------------
echo
echo "1. Fresh install drops every file where it should"
# ----------------------------------------------------------------------
H="$(new_home fresh)"
run_install "$H"

check "[[ -f '$H/$CFG/parquet.lua' ]]"                 "parquet.lua installed to ~/.config/hypr"
check "[[ -f '$H/$CFG/hyprland.lua' ]]"                "hyprland.lua created"
check "grep -qF 'require, \"parquet\"' '$H/$CFG/hyprland.lua'" "hyprland.lua requires parquet"
# The block sits in the user's compositor config, so a missing parquet.lua must
# not throw a config error across their whole desktop.
check "grep -qF 'pcall(require, \"parquet\")' '$H/$CFG/hyprland.lua'" \
      "the require is pcall'd so a missing parquet.lua cannot break the config"
# `require` is cached, so this second line is what re-binds the enabled
# workspaces after `hyprctl reload` re-runs hyprland.lua.
check "grep -qF '_G.parquet.apply_rules()' '$H/$CFG/hyprland.lua'" "managed block re-applies rules on reload"
# The block must NOT force a fresh module load: re-running the body calls
# hl.layout.register on a name that is still registered, which Hyprland reports
# as a config error on every reload.
check "! grep -qF 'package.loaded.parquet' '$H/$CFG/hyprland.lua'" \
      "managed block does not bust the require cache (would double-register)"
check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 1 ]]"     "exactly one managed block"
for f in manifest.json Parquet.js BarWidget.qml Panel.qml Editor.qml Service.qml LayoutCard.qml ZoneMark.qml; do
  check "[[ -f '$H/$PLUG/$f' ]]" "plugin file $f copied"
done
check "[[ -d '$H/$PLUG/layout' && -d '$H/$PLUG/assets' ]]"    "layout/ and assets/ copied"
check "[[ -f '$H/$ST' ]]"                              "state.json seeded"
check "grep -q '\"grid 2x2\"' '$H/$ST' && grep -q '\"2 stack\"' '$H/$ST'" "seed carries both presets"
# install.sh ships with the plugin (BarWidget runs it with --ensure on load);
# the rest of scripts/ is repo scaffolding and must stay out.
check "[[ -x '$H/$PLUG/scripts/install.sh' ]]"         "install.sh ships with the plugin, executable"
check "[[ ! -e '$H/$PLUG/scripts/test.sh' ]]"          "test.sh not copied into the plugin"
check "[[ ! -e '$H/$PLUG/scripts/test_install.sh' ]]"  "test_install.sh not copied into the plugin"
check "[[ ! -e '$H/$PLUG/scripts/gen-icon.sh' ]]"      "gen-icon.sh not copied into the plugin"

# ----------------------------------------------------------------------
echo
echo "2. Re-running install is idempotent and preserves user config"
# ----------------------------------------------------------------------
H="$(new_home idem)"
USER_CFG='# my hyprland config
monitor = eDP-1, preferred, auto, 1
bind = SUPER, Q, killactive'
mkdir -p "$H/$CFG"
printf '%s\n' "$USER_CFG" > "$H/$CFG/hyprland.lua"
BEFORE="$(rtrim_blanks "$H/$CFG/hyprland.lua")"

run_install "$H"
run_install "$H"
run_install "$H"

check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 1 ]]"          "still exactly one block after 3 installs"
check "[[ \$(grep -cF 'pcall(require, \"parquet\")' '$H/$CFG/hyprland.lua') -eq 1 ]]" "still exactly one require line"
check "grep -qxF 'monitor = eDP-1, preferred, auto, 1' '$H/$CFG/hyprland.lua'"  "user monitor line intact"
check "grep -qxF 'bind = SUPER, Q, killactive' '$H/$CFG/hyprland.lua'"          "user bind line intact"

# Backups must not pile up. Runs 2 and 3 changed nothing, so they must leave
# nothing behind; run 1 really did rewrite hyprland.lua, so one backup of it is
# fair. parquet.lua did not exist before run 1 and is byte-identical after, so
# it should have no backups at all.
bak_count() { ls -1 "$1".parquet-bak.* 2>/dev/null | wc -l; }
check "[[ \$(bak_count '$H/$CFG/hyprland.lua') -le 1 ]]" \
      "3 installs leave at most 1 hyprland.lua backup (no-op runs leave none)"
check "[[ \$(bak_count '$H/$CFG/parquet.lua') -eq 0 ]]" \
      "an unchanged parquet.lua is never backed up"

# And even a genuinely-changing file only keeps a bounded history.
for i in 1 2 3 4 5 6; do
  printf '# edit %s\n' "$i" >> "$H/$CFG/parquet.lua"
  run_install "$H"
done
check "[[ \$(bak_count '$H/$CFG/parquet.lua') -le 3 ]]" \
      "6 changing installs keep at most KEEP_BACKUPS(3) parquet.lua backups"
check "[[ \$(bak_count '$H/$CFG/hyprland.lua') -le 3 ]]" \
      "…and at most 3 hyprland.lua backups"

# Re-installing must never leave the LIVE hyprland.lua without the managed
# block, even for an instant: Hyprland reloads on config change, and a reload
# that reads a block-less config rebuilds its Lua state with no
# require("parquet") in it — lua:parquet stops existing and every Parquet
# workspace silently falls back to native tiling. Sample the file hard while a
# batch of installs runs; every non-empty read must still carry the block.
missing=0
( for i in $(seq 12); do run_install "$H"; done ) &
writer=$!
while kill -0 "$writer" 2>/dev/null; do
  if [[ -s $H/$CFG/hyprland.lua ]] && [[ $(mark_count "$H/$CFG/hyprland.lua") -eq 0 ]]; then
    missing=$((missing + 1))
  fi
done
wait "$writer" 2>/dev/null || true
check "[[ $missing -eq 0 ]]" "hyprland.lua always has the managed block while installs run ($missing bad reads)"

# ----------------------------------------------------------------------
echo
echo "3. Uninstall removes every trace and restores hyprland.lua"
# ----------------------------------------------------------------------
run_install "$H" --uninstall

AFTER="$(rtrim_blanks "$H/$CFG/hyprland.lua")"
check "[[ '$BEFORE' == '$AFTER' ]]"                    "hyprland.lua back to its pre-install content"
check "! grep -qF 'parquet' '$H/$CFG/hyprland.lua'"    "no 'parquet' left in hyprland.lua"
check "[[ ! -e '$H/$CFG/parquet.lua' ]]"               "parquet.lua removed"
check "[[ ! -e '$H/$PLUG' ]]"                          "plugin folder removed"
check "[[ -f '$H/$ST' ]]"                              "state.json kept (user's drawn layouts)"
# "every trace" has to include the backups install.sh made, or ~/.config/hypr
# keeps them forever.
check "[[ -z \"\$(ls -1 '$H/$CFG'/*.parquet-bak.* 2>/dev/null)\" ]]" \
      "no .parquet-bak.* files left behind"

# a user block sitting *after* the managed block must survive uninstall
H="$(new_home sandwich)"
mkdir -p "$H/$CFG"
printf 'line before\n' > "$H/$CFG/hyprland.lua"
run_install "$H"
printf 'line after\n' >> "$H/$CFG/hyprland.lua"
run_install "$H" --uninstall
check "grep -qxF 'line before' '$H/$CFG/hyprland.lua'" "content before the block survives uninstall"
check "grep -qxF 'line after'  '$H/$CFG/hyprland.lua'" "content after the block survives uninstall"

# ----------------------------------------------------------------------
echo
echo "4. A state.json the user has edited is never clobbered"
# ----------------------------------------------------------------------
H="$(new_home keepstate)"
run_install "$H"
printf '{"version":2,"layouts":{},"order":[],"workspaces":{"9":{"enabled":true,"layout":"grid 2x2"}}}' > "$H/$ST"
run_install "$H"
check "grep -q '\"9\"' '$H/$ST'"                       "second install keeps the user's state.json"

# ----------------------------------------------------------------------
echo
echo "5. --uninstall on a machine that never had Parquet is a clean no-op"
# ----------------------------------------------------------------------
H="$(new_home noop)"
if run_install "$H" --uninstall; then pass; else fail "uninstall with nothing installed exits 0"; fi

# ----------------------------------------------------------------------
echo
echo "6. Running from inside the installed plugin folder does not self-destruct"
# ----------------------------------------------------------------------
# `omarchy plugin add <git-url>` git-clones the repo straight into
# ~/.config/omarchy/plugins/<id>/, so REPO_DIR and PLUGIN_DEST become the SAME
# directory and the plugin-copy step's `rm -rf "$PLUGIN_DEST"` would delete the
# running script's own source tree.
H="$(new_home inplace)"
mkdir -p "$H/$CFG" "$H/.config/omarchy/plugins"
printf 'require("omarchy")\n' > "$H/$CFG/hyprland.lua"
cp -r "$REPO_DIR" "$H/$PLUG"
BEFORE_N="$(ls -1 "$H/$PLUG" | wc -l)"

if env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
       bash "$H/$PLUG/scripts/install.sh" >/dev/null 2>&1; then pass
else fail "install from inside the plugin folder exits 0"; fi

check "[[ \$(ls -1 '$H/$PLUG' | wc -l) -eq $BEFORE_N ]]" \
      "the plugin folder still has all $BEFORE_N entries (not deleted)"
check "[[ -f '$H/$PLUG/manifest.json' && -f '$H/$PLUG/Parquet.js' ]]" \
      "plugin files survive"
# the parts that DO still have work to do must have happened
check "[[ -f '$H/$CFG/parquet.lua' ]]"                 "the Lua shim is still installed"
check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 1 ]]" "the managed block is still added"
check "[[ -f '$H/$ST' ]]"                              "state.json is still seeded"

# ...and uninstalling from inside must not delete the folder out from under itself
env HOME="$H" XDG_CONFIG_HOME="$H/.config" XDG_STATE_HOME="$H/.local/state" \
    bash "$H/$PLUG/scripts/install.sh" --uninstall >/dev/null 2>&1
check "[[ -f '$H/$PLUG/manifest.json' ]]" "uninstall from inside leaves the folder to the plugin manager"
check "! grep -qF 'parquet' '$H/$CFG/hyprland.lua'"    "…but still cleans hyprland.lua"
check "[[ ! -e '$H/$CFG/parquet.lua' ]]"               "…and still removes the Lua shim"

# ----------------------------------------------------------------------
echo
echo "7. --ensure makes a bare 'omarchy plugin add' clone into a real install"
# ----------------------------------------------------------------------
# `omarchy plugin add <url>` git-clones the repo into the plugins dir and stops
# there — no Lua layout, no managed block, so lua:parquet does not exist. The
# widget runs install.sh --ensure on load to close that gap.
H="$(new_home ensure)"
mkdir -p "$H/$CFG" "$H/.config/omarchy/plugins"
printf 'require("omarchy")\n' > "$H/$CFG/hyprland.lua"
cp -r "$REPO_DIR" "$H/$PLUG"            # stand in for the git clone

check "[[ ! -e '$H/$CFG/parquet.lua' ]]"                "clone alone leaves no Lua layout"
check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 0 ]]" "clone alone adds no managed block"

run_ensure() {
  HOME="$1" XDG_CONFIG_HOME="$1/.config" XDG_STATE_HOME="$1/.local/state" \
  PATH="$STUB_BIN:$PATH" bash "$1/$PLUG/scripts/install.sh" --ensure >/dev/null 2>&1
}
run_ensure "$H"

check "[[ -f '$H/$CFG/parquet.lua' ]]"                  "--ensure installs the Lua layout"
check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 1 ]]" "--ensure adds exactly one managed block"
check "! grep -qF 'package.loaded.parquet' '$H/$CFG/hyprland.lua'" "--ensure block does not bust the require cache"
check "[[ -f '$H/$ST' ]]"                               "--ensure seeds state.json"
check "[[ -f '$H/$PLUG/manifest.json' ]]"               "--ensure does not eat the cloned plugin"

# Idempotent AND quiet: a second run must change nothing and leave no backups.
before="$(cat "$H/$CFG/hyprland.lua")"
nbak_before=$(ls -1 "$H/$CFG"/*.parquet-bak.* 2>/dev/null | wc -l)
run_ensure "$H"
run_ensure "$H"
after="$(cat "$H/$CFG/hyprland.lua")"
check "[[ '$before' == '$after' ]]"                     "repeat --ensure leaves hyprland.lua byte-identical"
check "[[ \$(ls -1 '$H/$CFG'/*.parquet-bak.* 2>/dev/null | wc -l) -eq $nbak_before ]]" \
      "repeat --ensure creates no new backups"
check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 1 ]]" "repeat --ensure never doubles the block"

# A half-broken install (someone deleted the Lua file) must self-heal.
rm -f "$H/$CFG/parquet.lua"
run_ensure "$H"
check "[[ -f '$H/$CFG/parquet.lua' ]]"                  "--ensure restores a deleted Lua layout"

# ----------------------------------------------------------------------
echo
echo "8. A hyprland.conf install is refused, not hijacked"
# ----------------------------------------------------------------------
# Hyprland prefers hyprland.lua over hyprland.conf when both exist, so creating
# a hyprland.lua holding only our managed block would make Hyprland ignore the
# user's whole .conf. The widget runs --ensure on its own, so this has to stop.
H="$(new_home confonly)"
mkdir -p "$H/$CFG"
CONF='monitor=,preferred,auto,1
bind=SUPER,Q,killactive'
printf '%s\n' "$CONF" > "$H/$CFG/hyprland.conf"

if run_install "$H"; then fail "install refuses on a .conf-only machine"; else pass; fi
check "[[ ! -e '$H/$CFG/hyprland.lua' ]]"   "no hyprland.lua is created (their .conf keeps winning)"
check "[[ ! -e '$H/$CFG/parquet.lua' ]]"    "…and no half-install is left behind"
check "diff -q <(printf '%s\\n' \"\$CONF\") '$H/$CFG/hyprland.conf' >/dev/null" \
      "the user's hyprland.conf is untouched"

# --ensure must refuse just as hard, since the widget calls it unattended.
if run_install "$H" --ensure; then fail "--ensure refuses on a .conf-only machine"; else pass; fi
check "[[ ! -e '$H/$CFG/hyprland.lua' ]]"   "--ensure creates no hyprland.lua either"

# But a machine with NEITHER file is a normal fresh install.
H="$(new_home neither)"
mkdir -p "$H/$CFG"
if run_install "$H"; then pass; else fail "install works when neither config exists"; fi
check "[[ -f '$H/$CFG/hyprland.lua' ]]"     "hyprland.lua is created when there is no .conf to break"
check "[[ \$(mark_count '$H/$CFG/hyprland.lua') -eq 1 ]]" "…with the managed block in it"

# ----------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ $FAIL -eq 0 ]]; then echo; echo "ALL CHECKS PASSED"; exit 0
else echo; echo "THERE ARE FAILURES"; exit 1; fi
