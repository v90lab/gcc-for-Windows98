#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# prepare-binutils-gdb.sh - Prepare binutils-gdb sources
# ============================================================================
# Applies the Win98 patch series to /work/src/binutils-gdb. Tarball-extracted
# (no .git), so no `git reset` — apply-patches.sh's `patch -p1 -N` fallback
# is idempotent on its own.
#
# The current patch (0001-mingw-hdep-poll-console-input-on-win9x.patch) only
# touches gdb/mingw-hdep.c, which is consumed by build-native-gdb. Cross
# binutils, native binutils, and gdbserver don't include it (--disable-gdb).
# So after applying the patch we invalidate the downstream sentinels so a
# previously-built (unpatched) gdb.exe gets rebuilt + repackaged on the next
# run.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_dir "$SRC_DIR/binutils-gdb" "missing binutils-gdb sources; run fetch-sources.sh first"
skip_if_done prepare-binutils-gdb

run_logged prepare-binutils-gdb.log "$ROOT_DIR/scripts/apply-patches.sh" binutils-gdb "$BINUTILS_COMPONENT_VERSION"

for downstream in build-native-gdb verify-extras-package package-extras-toolset write-extras-toolchain-manifest-v2; do
    sentinel="$(status_file "$downstream")"
    if [[ -f "$sentinel" ]]; then
        log "invalidating downstream sentinel: $downstream"
        rm -f "$sentinel"
    fi
done

mark_done prepare-binutils-gdb
log "prepare binutils-gdb complete"
