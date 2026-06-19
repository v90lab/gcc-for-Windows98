#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-gdb.sh - Build gdb for the extras toolset
# ============================================================================
# Reuses the existing binutils-gdb source tree (we already fetch
# binutils-2_36_1, which carries gdb 10.1). Builds gdb out-of-tree with
# binutils/ld/gas/gprof/sim disabled at install time so the gdb binary
# lands cleanly under out/extras-toolset/.
#
# All optional dependencies (python, expat, mpfr, lzma, zstd, debuginfod,
# source-highlight, curses, readline) are disabled so the resulting gdb
# only links against msvcrt, pthread9x, and the native GMP we already
# build for the Canadian Cross host GCC.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
GDB_SRC="$REPO_ROOT/src/binutils-gdb"
BUILD_DIR="$REPO_ROOT/build/gdb-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"
MINGW_DEPS_DIR="$REPO_ROOT/out/mingw-deps"

skip_if_done build-native-gdb

# === STEP 1: Verify prerequisites ===
require_dir "$GDB_SRC" "Missing binutils-gdb sources at $GDB_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

# gdb wants GMP. We reuse the Win98-native libgmp.a built for native-host GCC.
require_step build-native-mingw-deps "run build-native-mingw-deps.sh first (gdb needs Win98-native libgmp.a)"
require_file "$MINGW_DEPS_DIR/lib/libgmp.a" "Missing $MINGW_DEPS_DIR/lib/libgmp.a"

export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 2: Configure (out-of-tree, top-level binutils-gdb configure) ===
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "configuring gdb for $TARGET"
run_logged build-native-gdb.log "$GDB_SRC/configure" \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET" \
    --target="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --enable-gdb \
    --disable-binutils \
    --disable-ld \
    --disable-gas \
    --disable-gold \
    --disable-gprof \
    --disable-sim \
    --disable-nls \
    --disable-werror \
    --disable-source-highlight \
    --without-python \
    --without-guile \
    --without-expat \
    --without-mpfr \
    --without-lzma \
    --without-zstd \
    --without-debuginfod \
    --with-libgmp-prefix="$MINGW_DEPS_DIR" \
    --enable-tui=no \
    --without-curses \
    --without-readline \
    CPPFLAGS="$WIN98_TARGET_CPPFLAGS" \
    LDFLAGS="-static-libgcc -static-libstdc++ -Wl,--allow-multiple-definition $WIN98_TARGET_LDFLAGS"

# === STEP 3: Build & install ===
log "building gdb"
run_logged build-native-gdb.log make -j"$JOBS" MAKEINFO=true

log "installing gdb to $INSTALL_DIR"
run_logged build-native-gdb.log make install MAKEINFO=true

require_file "$INSTALL_DIR/bin/gdb.exe" "gdb install produced no gdb.exe"

mark_done build-native-gdb
log "gdb build complete"
