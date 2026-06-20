#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-ctags.sh - Build universal-ctags for the extras toolset
# ============================================================================
# Cross-compiles universal-ctags from its git tree. The tree ships
# autogen.sh which invokes autoreconf to materialize configure. Optional
# external parser libraries (libxml2, jansson, libyaml, libseccomp) are
# disabled to avoid extra Win98 dependencies.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
CTAGS_SRC="$REPO_ROOT/src/ctags"
BUILD_DIR="$REPO_ROOT/build/ctags-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-ctags

# === STEP 1: Verify prerequisites ===
require_dir "$CTAGS_SRC" "Missing ctags sources at $CTAGS_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 2: Generate configure via autogen.sh ===
log "running autogen.sh for universal-ctags"
( cd "$CTAGS_SRC" && run_logged build-native-ctags.log ./autogen.sh )

# === STEP 3: Configure (out-of-tree) ===
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "configuring universal-ctags for $TARGET"
# ctags' configure.ac defaults WINDRES to bare `windres` if unset (see
# configure.ac:330-335), and the cross prefix on PATH isn't enough — autoconf
# AC_ARG_VAR records the precious value into the Makefile only when passed
# explicitly. Without this the win32 resource compile fails with
# "windres: command not found".
run_logged build-native-ctags.log "$CTAGS_SRC/configure" \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --disable-external-parser-libs \
    --disable-iconv \
    --enable-static \
    WINDRES="${TARGET}-windres" \
    CPPFLAGS="$WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS" \
    LDFLAGS="-static-libgcc $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

# === STEP 4: Build & install ===
log "building universal-ctags"
run_logged build-native-ctags.log make -j"$JOBS"

log "installing universal-ctags to $INSTALL_DIR"
run_logged build-native-ctags.log make install

require_file "$INSTALL_DIR/bin/ctags.exe" "universal-ctags install produced no ctags.exe"

mark_done build-native-ctags
log "universal-ctags build complete"
