#!/usr/bin/env bash
#
# Runs every Parquet test suite. No compositor or shell needed.
#
#   scripts/test.sh
#
# Exits non-zero if any suite fails.

set -uo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

rc=0
run() {
  printf '\n\033[1m>>> %s\033[0m\n' "$1"; shift
  if "$@"; then :; else rc=1; printf '\033[31m<<< FAILED\033[0m\n'; fi
}

run "layout/test_parquet.lua  (Lua engine)"      sh -c 'cd layout && lua test_parquet.lua'
if command -v luajit >/dev/null; then
  run "layout/test_parquet.lua  (luajit)"        sh -c 'cd layout && luajit test_parquet.lua'
fi
run "layout/test_parquet_js.js  (shared JS)"     sh -c 'cd layout && node test_parquet_js.js'
run "scripts/test_install.sh  (installer)"       bash scripts/test_install.sh

if [[ $rc -eq 0 ]]; then printf '\n\033[32mALL SUITES PASSED\033[0m\n'; else printf '\n\033[31mSOME SUITES FAILED\033[0m\n'; fi
exit $rc
