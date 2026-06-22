#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-jq.sh - Build jq for the extras toolset
# ============================================================================
# Cross-compiles jq 1.8.2 from the upstream release tarball, which ships a
# pre-generated `configure`, pre-generated lexer.c/parser.c, vendored
# oniguruma (regex), and vendored decNumber. Installs jq.exe under
# out/extras-toolset/.
#
# Build is C-only (jq doesn't need libstdc++), pulls pthread9x transparently
# via mingw-w64's -pthread, uses the vendored oniguruma via
# --with-oniguruma=builtin so we don't need to wire onig as a separate
# component. Static linkage end-to-end (--disable-shared) — Win98 doesn't
# benefit from a shared libjq.dll and avoiding it sidesteps libtool's
# win32-dll mode.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
JQ_SRC="$REPO_ROOT/src/jq"
BUILD_DIR="$REPO_ROOT/build/jq-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-jq

# === STEP 1: Verify prerequisites ===
require_dir "$JQ_SRC" "Missing jq sources at $JQ_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 2: Configure (out-of-tree) ===
require_file "$JQ_SRC/configure" "Missing pre-built configure at $JQ_SRC/configure (release tarball should ship one)"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "configuring jq for $TARGET"
# --with-oniguruma=builtin: AC_CONFIG_SUBDIRS into vendor/oniguruma, no
#   external libonig dependency. Onig is portable C and clean on Win98.
# --disable-shared: skip libjq.dll. jq.exe statically links the .a; libtool's
#   win32-dll mode would otherwise try to build an import library + dll for
#   libjq with no consumer.
# --disable-maintainer-mode: explicit (it's also the default per
#   AM_MAINTAINER_MODE([disable])). Skips the bison/flex regen path —
#   tarball ships pre-generated lexer.c / parser.c.
# --disable-docs: docs build needs Python + pipenv; we have neither in
#   the toolchain-builder image. jq.1.prebuilt ships in the tarball so the
#   man page is still present (unused on Win98).
# --disable-valgrind / --disable-asan / etc: defaults already off, no-op.
run_logged build-native-jq.log "$JQ_SRC/configure" \
    --build=x86_64-pc-linux-gnu \
    --host="$TARGET" \
    --prefix="$INSTALL_DIR" \
    --with-oniguruma=builtin \
    --disable-shared \
    --enable-static \
    --disable-maintainer-mode \
    --disable-docs \
    --disable-dependency-tracking \
    CPPFLAGS="$WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS" \
    LDFLAGS="-static-libgcc $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

# === STEP 3: Build & install ===
log "building jq"
run_logged build-native-jq.log make -j"$JOBS"

log "installing jq to $INSTALL_DIR"
run_logged build-native-jq.log make install

require_file "$INSTALL_DIR/bin/jq.exe" "jq install produced no jq.exe"

mark_done build-native-jq
log "jq build complete"
