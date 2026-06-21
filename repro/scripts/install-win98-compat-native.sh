#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# install-win98-compat-native.sh - Mirror the win98-compat shim into the
# native toolset so on-Win98 ports can use it
# ============================================================================
# build-win98-compat.sh installs libwin98compat.a + win98_compat.h into the
# CROSS toolchain's sysroot (out/toolchain/i686-w64-mingw32/{lib,include}/).
# The NATIVE toolset (out/native-toolset/, packaged as gcc-win98-native-
# toolset.zip) has its own sysroot at out/native-toolset/i686-w64-mingw32/...
# and doesn't pick up the shim automatically.
#
# When a user installs the native toolset on Win98 and tries to port more
# software there, they want the same `-include win98_compat.h` / `-lwin98compat`
# convenience that the build pipeline uses for the extras tools. This script
# copies the artifacts into the native sysroot and bundles the source under
# share/win98-compat/ for reference (the source is also useful if someone
# wants to add another shimmed function on-Win98).
#
# The shim is a static archive targeting i686-w64-mingw32 — identical target
# triple as the native toolset's mingw runtime — so the cross-built .a is
# bit-identical to what a native rebuild would produce. No recompilation
# needed; we just file-copy.
#
# Installed layout under out/native-toolset/:
#   i686-w64-mingw32/include/win98_compat.h     <- standard include path
#   i686-w64-mingw32/lib/libwin98compat.a       <- standard library path
#   share/win98-compat/src/win98_compat.c       <- reference source
#   share/win98-compat/include/win98_compat.h   <- header next to source
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_step build-win98-compat "win98-compat shim must be built first (CROSS phase)"
require_step build-native-mingw-w64 "native sysroot (i686-w64-mingw32/{include,lib}) must exist first"

CROSS_SYSROOT="$ROOT_DIR/out/toolchain/$TARGET"
NATIVE_SYSROOT="$ROOT_DIR/out/native-toolset/$TARGET"
SHIM_SRC_DIR="$ROOT_DIR/win98-compat"
SHARE_DIR="$ROOT_DIR/out/native-toolset/share/win98-compat"

# Invalidate on either the cross-built artifact (changes when build-win98-compat
# re-runs) or the in-tree source (changes when we edit the shim — defensive,
# normally caught by the build-win98-compat invalidation first).
invalidate_if_stale install-win98-compat-native \
    "$CROSS_SYSROOT/lib/libwin98compat.a" \
    "$CROSS_SYSROOT/include/win98_compat.h" \
    "$SHIM_SRC_DIR/src/win98_compat.c" \
    "$SHIM_SRC_DIR/include/win98_compat.h"
skip_if_done install-win98-compat-native

require_file "$CROSS_SYSROOT/lib/libwin98compat.a" "missing libwin98compat.a in cross sysroot (run build-win98-compat first)"
require_file "$CROSS_SYSROOT/include/win98_compat.h" "missing win98_compat.h in cross sysroot (run build-win98-compat first)"
require_dir "$NATIVE_SYSROOT/lib" "native sysroot lib/ missing (run build-native-mingw-w64 first)"
require_dir "$NATIVE_SYSROOT/include" "native sysroot include/ missing (run build-native-mingw-w64 first)"
require_file "$SHIM_SRC_DIR/src/win98_compat.c" "missing in-tree shim source at $SHIM_SRC_DIR/src/win98_compat.c"
require_file "$SHIM_SRC_DIR/include/win98_compat.h" "missing in-tree shim header at $SHIM_SRC_DIR/include/win98_compat.h"

log "installing libwin98compat.a and win98_compat.h into native sysroot"
install -m 0644 "$CROSS_SYSROOT/lib/libwin98compat.a" "$NATIVE_SYSROOT/lib/libwin98compat.a"
install -m 0644 "$CROSS_SYSROOT/include/win98_compat.h" "$NATIVE_SYSROOT/include/win98_compat.h"

log "bundling shim source under share/win98-compat/"
mkdir -p "$SHARE_DIR/src" "$SHARE_DIR/include"
install -m 0644 "$SHIM_SRC_DIR/src/win98_compat.c" "$SHARE_DIR/src/win98_compat.c"
install -m 0644 "$SHIM_SRC_DIR/include/win98_compat.h" "$SHARE_DIR/include/win98_compat.h"

# Sanity check: confirm the cross and native .a are byte-identical. Catches
# a future regression where someone slips a different cross-compile of the
# shim into one tree but not the other (e.g. via a stale build dir or a
# patched build script).
if ! cmp -s "$CROSS_SYSROOT/lib/libwin98compat.a" "$NATIVE_SYSROOT/lib/libwin98compat.a"; then
    die "libwin98compat.a differs between cross and native sysroot — install copy is corrupt"
fi

mark_done install-win98-compat-native
log "win98-compat shim mirrored into native toolset"
