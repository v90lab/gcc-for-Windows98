#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-host-gcc.sh - Build native-host GCC (Canadian Cross)
# ============================================================================
# CRITICAL: This script MUST use the newly built cross-toolchain (GCC 11) as
# the build compiler. Using the system-provided i686-w64-mingw32-gcc (usually
# GCC 10) will fail because GCC 11's libstdc++ requires __is_nothrow_constructible
# and other builtins not present in GCC 10.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
SRC_DIR="$REPO_ROOT/src/gcc"
BUILD_DIR="$REPO_ROOT/build/gcc-native-host"
INSTALL_DIR="$REPO_ROOT/out/native-toolset"
CROSS_TOOLCHAIN_DIR="$REPO_ROOT/out/toolchain"
MINGW_DEPS_DIR="$REPO_ROOT/out/mingw-deps"

# === STEP 1: Verify prerequisites ===
require_dir "$SRC_DIR" "Missing GCC sources at $SRC_DIR"
require_dir "$CROSS_TOOLCHAIN_DIR/bin" "Cross-toolchain not found at $CROSS_TOOLCHAIN_DIR"
require_step build-native-mingw-deps "run build-native-mingw-deps.sh first"
require_dir "$MINGW_DEPS_DIR/include" "Missing native dependency headers at $MINGW_DEPS_DIR/include"
require_dir "$MINGW_DEPS_DIR/lib" "Missing native dependency libraries at $MINGW_DEPS_DIR/lib"
# NOTE: build-native-mingw-w64 MUST run before this step so that
# out/native-toolset/i686-w64-mingw32/include is populated with the mingw-w64
# headers (including fenv.h). GCC's libstdc++ build adds that directory via
# -isystem, and the c_compatibility/fenv.h wrapper's #include_next <fenv.h>
# must find the real fenv.h there for _GLIBCXX_USE_C99_FENV_TR1 to compile.
require_step build-native-mingw-w64 "run build-native-mingw-w64.sh before build-native-host-gcc.sh"
require_dir "$INSTALL_DIR/i686-w64-mingw32/include" "Missing native-toolset mingw headers (run build-native-mingw-w64.sh first)"

# === STEP 2: Ensure we use the new cross-toolchain ===
# Prepend to PATH so configure finds our GCC 11 instead of system GCC 10
# Also add system gcc libexec so build compiler cc1plus is found
export PATH="/usr/lib/gcc/x86_64-linux-gnu/13:$CROSS_TOOLCHAIN_DIR/bin:$PATH"

# Fix liblto_plugin.so path for the build compiler
export LIBRARY_PATH="/usr/lib/gcc/x86_64-linux-gnu/13${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="/usr/lib/gcc/x86_64-linux-gnu/13${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# Verify compiler version
echo "=== Build Compiler Verification ==="
echo "Compiler path: $(which i686-w64-mingw32-gcc)"
echo "Compiler version:"
i686-w64-mingw32-gcc --version | head -n 1
echo ""

# === STEP 3: Clean and create build directory ===
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Create mingw/include symlink in sysroot to satisfy GCC's fixincludes
SYSROOT_MINGW="$CROSS_TOOLCHAIN_DIR/i686-w64-mingw32/mingw"
if [[ ! -d "$SYSROOT_MINGW/include" ]]; then
    echo "=== Creating mingw/include symlink in sysroot ==="
    mkdir -p "$SYSROOT_MINGW"
    ln -sf "$CROSS_TOOLCHAIN_DIR/i686-w64-mingw32/include" "$SYSROOT_MINGW/include"
fi

cd "$BUILD_DIR"

# === STEP 4: Configure GCC ===
# Notes:
# - --disable-libstdcxx-pch: Avoids PCH compatibility issues in Canadian Cross builds
# - The native-host compiler links against the explicit mingw-deps prefix.
# - --disable-lto: Avoids liblto_plugin.so issues with the build compiler
# - CC_FOR_BUILD/CXX_FOR_BUILD: Use system gcc which has working cc1plus
# - ccache wrapping: GCC uses THREE separate compiler-variable namespaces.
#     * CC/CXX (from common.sh env) — HOST-stage compilation: the Win98 gcc
#       binary itself (gcc.exe, cc1.exe, cc1plus.exe). Already wrapped.
#     * CC_FOR_BUILD/CXX_FOR_BUILD — build-side helpers (gen* programs that
#       run during the build to produce source). PATH-shim from /usr/lib/ccache
#       can't wrap these because the script hardcodes absolute /usr/bin/gcc;
#       prefix with `ccache` explicitly.
#     * CC_FOR_TARGET/CXX_FOR_TARGET/GCC_FOR_TARGET — target-library
#       compilation (libgcc, libstdc++, multilib lib32/lib64). Derived from
#       --target=, NOT inherited from CC; same PATH-shim defeat. Without the
#       explicit `ccache` prefix here, the lib32/* phase runs uncached even
#       on rebuilds where every input is unchanged. (Confirmed via `ccache -s`
#       showing 0 hit/miss delta during the target-libs phase.)

log "using native dependency prefix: $MINGW_DEPS_DIR"

# Inject WIN98_TARGET_{CPPFLAGS,LDFLAGS} via env. --host=i686-w64-mingw32, so
# host-built binaries (gcc.exe, g++.exe, cc1.exe, cc1plus.exe, ...) run on
# Win98 and need these flags. We don't touch FLAGS_FOR_TARGET — those build
# the libgcc/libstdc++ that user programs link against, where Win98-host
# linker quirks don't apply.
export CPPFLAGS="${CPPFLAGS:-} $WIN98_TARGET_CPPFLAGS"
export LDFLAGS="${LDFLAGS:-} $WIN98_TARGET_LDFLAGS"

log "configuring native-host GCC"
run_logged configure-native-host-gcc.log "$SRC_DIR/configure" \
    --build=x86_64-pc-linux-gnu \
    --host=i686-w64-mingw32 \
    --target=i686-w64-mingw32 \
    --prefix="$INSTALL_DIR" \
    --enable-languages=c,c++ \
    --disable-bootstrap \
    --disable-shared \
    --enable-static \
    --with-gmp="$MINGW_DEPS_DIR" \
    --with-mpfr="$MINGW_DEPS_DIR" \
    --with-mpc="$MINGW_DEPS_DIR" \
    --with-sysroot="$CROSS_TOOLCHAIN_DIR/i686-w64-mingw32" \
    --enable-threads=posix \
    --disable-sjlj-exceptions \
    --with-default-msvcrt=msvcrt \
    --disable-libssp \
    --disable-libquadmath \
    --disable-libgomp \
    --disable-libatomic \
    --disable-libstdcxx-pch \
    --disable-lto \
    --without-isl \
    CC_FOR_BUILD="ccache /usr/bin/gcc" \
    CXX_FOR_BUILD="ccache /usr/bin/g++" \
    CC_FOR_TARGET="ccache ${TARGET}-gcc" \
    CXX_FOR_TARGET="ccache ${TARGET}-g++" \
    GCC_FOR_TARGET="ccache ${TARGET}-gcc" \
    glibcxx_cv_stdio_eof=-1 \
    glibcxx_cv_stdio_seek_cur=1 \
    glibcxx_cv_stdio_seek_set=0 \
    glibcxx_cv_stdio_seek_end=2

# Verify build compiler can find cc1plus
# cc1plus location varies; find the right one; this verification is informational
echo "=== Build Compiler PATH Fix Verification ==="
/usr/bin/gcc --version | head -n 1
find /usr/libexec/gcc/x86_64-linux-gnu -name cc1plus 2>/dev/null | head -1 || echo "cc1plus not found at expected path, but build may proceed"

# === STEP 5: Build ===
# Full build including libstdc++-v3. This requires that build-native-mingw-w64
# has already run so that out/native-toolset/i686-w64-mingw32/include is
# populated. Without those headers, the libstdc++ c_compatibility/fenv.h
# wrapper's #include_next <fenv.h> chain cannot find fenv_t in ::, which
# breaks the libstdc++-v3/src/c++17/floating_from_chars.cc compilation.
log "building native-host GCC"
run_logged build-native-host-gcc.log make -j"$(nproc)" || {
    echo "ERROR: Parallel build failed, retrying with -j1 for error visibility..." >&2
    run_logged build-native-host-gcc.log make -j1
    exit 1
}

# === STEP 6: Install ===
log "installing native-host GCC"
run_logged install-native-host-gcc.log make install

# === STEP 7: Verify output ===
echo "=== Verification ==="
echo "Installed binaries:"
ls -la "$INSTALL_DIR/bin/"*.exe 2>/dev/null | head -10 || echo "No .exe files found"
echo ""
echo "Native host GCC built successfully at: $INSTALL_DIR"
mark_done build-native-host-gcc
