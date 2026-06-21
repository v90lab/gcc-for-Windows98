#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# prepare-busybox-w32.sh - Prepare busybox-w32 sources
# ============================================================================
# build-native-busybox.sh applies the patch series itself (the apply step is
# idempotent: `git apply --check` then `patch -p1 -N` fallback), so all this
# step needs to do is invalidate downstream sentinels when new patches land.
# Without that, a user who has already produced busybox.exe / the extras
# package keeps shipping the unpatched binaries because the sentinels gate
# the actual rebuild.
#
# Mirrors prepare-binutils-gdb.sh — same shape, different downstreams.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_dir "$SRC_DIR/busybox-w32" "missing busybox-w32 sources; run fetch-sources.sh first"
skip_if_done prepare-busybox-w32

for downstream in build-native-busybox build-bb-shims verify-extras-package package-extras-toolset write-extras-toolchain-manifest-v2; do
    sentinel="$(status_file "$downstream")"
    if [[ -f "$sentinel" ]]; then
        log "invalidating downstream sentinel: $downstream"
        rm -f "$sentinel"
    fi
done

mark_done prepare-busybox-w32
log "prepare busybox-w32 complete"
