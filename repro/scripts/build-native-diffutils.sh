#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-diffutils.sh - Build GNU diffutils for the extras toolset
# ============================================================================
# Cross-compiles diffutils from the upstream release tarball, which ships a
# pre-generated `configure` and bundled gnulib m4 macros (same pattern as
# GNU make — avoids ./bootstrap and the gnulib clone it implies).
# Installs diff.exe, diff3.exe, sdiff.exe, cmp.exe under out/extras-toolset.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
DIFFUTILS_SRC="$REPO_ROOT/src/diffutils"
BUILD_DIR="$REPO_ROOT/build/diffutils-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-diffutils

# === STEP 1: Verify prerequisites ===
require_dir "$DIFFUTILS_SRC" "Missing diffutils sources at $DIFFUTILS_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 2: Configure (out-of-tree) ===
require_file "$DIFFUTILS_SRC/configure" "Missing pre-built configure at $DIFFUTILS_SRC/configure (release tarball should ship one)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "configuring GNU diffutils for $TARGET"
# CPPFLAGS notes:
#   -D_USE_32BIT_TIME_T — pin mingw-w64's time_t to 32 bits so gmtime() etc.
#     resolve to msvcrt's _gmtime32 instead of _gmtime64 (Win98's msvcrt.dll
#     only exports the 32-bit variants). Without this, diff.exe fails to
#     load on Win98 with a missing __gmtime64 import.
#   -DSA_RESTART=0 — diffutils's bundled gnulib uses the POSIX sigaction flag
#     SA_RESTART in lib/cmpbuf.c, but doesn't activate gnulib's signal-module
#     replacement header that would normally #define it to 0 on platforms
#     without POSIX signals. mingw has no signals model, so 0 (matching what
#     gnulib's replacement would emit) is the semantically-correct value.
#   -DSIGHUP=1 / -DSIGPIPE=13 — Windows's signal.h has no SIGHUP/SIGPIPE
#     (no terminal-disconnect or broken-pipe concepts). src/util.c installs
#     cleanup handlers for them anyway. Defining them to unused-on-Windows
#     signal numbers means signal() returns SIG_ERR at runtime and the handler
#     never installs — the signal can't fire on Windows, so it's a no-op.
run_logged build-native-diffutils.log "$DIFFUTILS_SRC/configure" \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --disable-nls \
    --disable-dependency-tracking \
    --disable-gcc-warnings \
    CPPFLAGS="-D_USE_32BIT_TIME_T -DSA_RESTART=0 -DSIGHUP=1 -DSIGPIPE=13 -DSIGSTOP=17 $WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS" \
    LDFLAGS="-static-libgcc $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

# === STEP 3: Build & install ===
log "building GNU diffutils"
run_logged build-native-diffutils.log make -j"$JOBS" MAKEINFO=true

log "installing GNU diffutils to $INSTALL_DIR"
run_logged build-native-diffutils.log make install MAKEINFO=true

require_file "$INSTALL_DIR/bin/diff.exe" "GNU diffutils install produced no diff.exe"

mark_done build-native-diffutils
log "GNU diffutils build complete"
