#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-win98-helpers-native.sh - Bundle setenv.bat + check-versions.bat
# into the native toolset
# ============================================================================
# Drops the two Win98-host helper batch files into out/native-toolset/ so the
# packaged zip ships them alongside bin/. Both files live at the toolset root
# (next to bin/) so a user runs them via `setenv.bat` / `check-versions.bat`
# from the unpacked package's top dir.
#
#   setenv.bat         — sets HOME / HOMEDRIVE / HOMEPATH / TMP / TEMP on
#                        Win98 SE where they're not set by default. Several
#                        tools (gdb, busybox sh, vi, make, ctags, muon) need
#                        these for full functionality (~ expansion, cache
#                        dirs, command history, ...). Safe to re-run.
#   check-versions.bat — smoke-tests every shipped tool by invoking it with
#                        --version (or equivalent). Calls setenv.bat first
#                        if it's present in the cwd.
#
# Mirror copy lives in the extras toolset via install-win98-helpers-extras.sh
# — see that script's header for why we ship them in both packages.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

skip_if_done install-win98-helpers-native

DEST_DIR="$ROOT_DIR/out/native-toolset"
SRC_BATCH_DIR="$ROOT_DIR/scripts/win98"

require_dir "$DEST_DIR" "native toolset not found at $DEST_DIR (run native build steps first)"
require_file "$SRC_BATCH_DIR/setenv.bat" "missing $SRC_BATCH_DIR/setenv.bat"
require_file "$SRC_BATCH_DIR/check-versions.bat" "missing $SRC_BATCH_DIR/check-versions.bat"

log "installing Win98 helper batch files into $DEST_DIR (LF -> CRLF)"
# Source files are LF for editor friendliness; convert to CRLF on install so
# the shipped .bat files use the line ending command.com expects.
for bat in setenv.bat check-versions.bat; do
    sed 's/\r$//; s/$/\r/' "$SRC_BATCH_DIR/$bat" > "$DEST_DIR/$bat"
    chmod 0644 "$DEST_DIR/$bat"
done

mark_done install-win98-helpers-native
log "Win98 helper batch files installed"
