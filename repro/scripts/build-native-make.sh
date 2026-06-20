#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-make.sh - Build GNU make for the extras toolset
# ============================================================================
# Cross-compiles GNU make from the upstream release tarball, which ships a
# pre-generated `configure` and bundled gnulib m4 macros. The git tree
# would require ./bootstrap (which pulls a fresh gnulib clone) — the
# tarball avoids both that dep and the resulting reproducibility headache.
# Produces make.exe installed under out/extras-toolset.
#
# At runtime on Windows 98 the recipes need a POSIX shell — pair with
# busybox.exe / sh.exe from build-native-busybox.sh, e.g.
#     make SHELL=sh.exe
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
MAKE_SRC="$REPO_ROOT/src/make"
BUILD_DIR="$REPO_ROOT/build/make-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-make

# === STEP 1: Verify prerequisites ===
require_dir "$MAKE_SRC" "Missing make sources at $MAKE_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 1b: Apply Win98 source patches ===
# 0001-skip-nt-security-descriptor-on-win98.patch drops the
# InitializeSecurityDescriptor call in src/w32/subproc/sub_proc.c, which is
# a stub-only export on Win98 SE's advapi32.dll (binds but always fails).
# Idempotent via apply-patches.sh's `patch -p1 -N` fallback (make is a
# tarball extract, not a git tree — git apply --check fails and we fall
# through to patch -N which silently skips already-applied hunks).
log "applying GNU make patches"
"$REPO_ROOT/scripts/apply-patches.sh" make "${MAKE_COMPONENT_VERSION:-4.4.1}"

# === STEP 2: Configure (out-of-tree) ===
require_file "$MAKE_SRC/configure" "Missing pre-built configure at $MAKE_SRC/configure (release tarball should ship one)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "configuring GNU make for $TARGET"
# -D_WIN98_PORT is consumed by the Win98 patch above: gates the
# InitializeSecurityDescriptor call out and substitutes NULL for the
# inheritable-pipe lpSecurityDescriptor (Win9x ignores SDs anyway).
run_logged build-native-make.log "$MAKE_SRC/configure" \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --without-guile \
    --disable-nls \
    --disable-dependency-tracking \
    CPPFLAGS="-D_WIN98_PORT $WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS" \
    LDFLAGS="-static-libgcc $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

# === STEP 3: Build & install ===
log "building GNU make"
run_logged build-native-make.log make -j"$JOBS" MAKEINFO=true

log "installing GNU make to $INSTALL_DIR"
run_logged build-native-make.log make install MAKEINFO=true

require_file "$INSTALL_DIR/bin/make.exe" "GNU make install produced no make.exe"

mark_done build-native-make
log "GNU make build complete"
