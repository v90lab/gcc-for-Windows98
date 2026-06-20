#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-binutils.sh - Build native-host binutils (Canadian Cross)
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
SRC_DIR="$REPO_ROOT/src/binutils-gdb"
BUILD_DIR="$REPO_ROOT/build/binutils-native-host"
INSTALL_DIR="$REPO_ROOT/out/native-toolset"
CROSS_TOOLCHAIN_DIR="$REPO_ROOT/out/toolchain"

# Ensure logs directory exists
mkdir -p "$REPO_ROOT/logs"

# === STEP 1: Verify prerequisites ===
require_dir "$SRC_DIR" "Missing binutils sources at $SRC_DIR"
require_dir "$CROSS_TOOLCHAIN_DIR/bin" "Cross-toolchain not found at $CROSS_TOOLCHAIN_DIR"

# Note: the gnulib stat-w32.c _WIN32_WINNT bump and gdb/gdbserver
# GetSystemWow64DirectoryA call sites used to be inline-python-patched
# here. The Win98 compat shim (libwin98compat.a, force-included via
# WIN98_COMPAT_CPPFLAGS) now subsumes both:
#   - GetFinalPathNameByHandleA (the symbol gnulib's bump was chasing) is
#     macro-redirected to win98_GetFinalPathNameByHandleA which probes via
#     GetProcAddress and stubs out cleanly on Win9x.
#   - GetSystemWow64DirectoryA likewise redirects to a probe-and-fallback
#     wrapper at every call site.
# See repro/win98-compat/ for the shim source.

# === STEP 2: Ensure we use the new cross-toolchain ===
export PATH="$CROSS_TOOLCHAIN_DIR/bin:$PATH"

# Verify compiler version
echo "=== Build Compiler Verification ==="
echo "Compiler path: $(which i686-w64-mingw32-gcc)"
i686-w64-mingw32-gcc --version | head -n 1
echo ""

# === STEP 3: Clean and create build directory ===
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# === STEP 4: Configure binutils ===
# Inject WIN98_TARGET_{CPPFLAGS,LDFLAGS} via env so configure propagates them
# to every host-binary link (--host=i686-w64-mingw32 means host = Win98).
export CPPFLAGS="${CPPFLAGS:-} $WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS"
# -static-libgcc / -static-libstdc++ matches the project's static-linking
# design (see top-level README). Almost all binutils binaries are plain C so
# these flags are a no-op for them; the one that needs them is gdbserver,
# which otherwise picks up libgcc_s_dw2-1.dll and is unloadable on Win98.
export LDFLAGS="${LDFLAGS:-} -static-libgcc -static-libstdc++ $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

log "configuring native-host binutils"
run_logged configure-native-host-binutils.log "$SRC_DIR/configure" \
    --build=x86_64-pc-linux-gnu \
    --host=i686-w64-mingw32 \
    --target=i686-w64-mingw32 \
    --prefix="$INSTALL_DIR" \
    --disable-nls \
    --disable-werror \
    --disable-gprof \
    --disable-gdb \
    --disable-sim \
    --disable-libdecnumber \
    --disable-readline \
    --disable-install-libbfd \
    --with-sysroot="$CROSS_TOOLCHAIN_DIR/i686-w64-mingw32"

# === STEP 5: Build ===
log "building native-host binutils"
# Workaround: Disable info documentation to avoid makeinfo dependency
run_logged build-native-host-binutils.log make -j"$(nproc)" MAKEINFO=true

# === STEP 6: Install ===
log "installing native-host binutils"
run_logged install-native-host-binutils.log make install MAKEINFO=true

# === STEP 7: Verify output ===
echo "=== Verification ==="
for tool in as ld ar nm ranlib strip objcopy objdump; do
    if [[ -f "$INSTALL_DIR/bin/$tool.exe" ]]; then
        echo "Found $tool.exe: $(file "$INSTALL_DIR/bin/$tool.exe")"
    else
        warn "$tool.exe not found!"
        # Check if they are prefixed
        if [[ -f "$INSTALL_DIR/bin/i686-w64-mingw32-$tool.exe" ]]; then
            echo "Found prefixed version: i686-w64-mingw32-$tool.exe"
            echo "Creating symlink/copy for $tool.exe"
            cp "$INSTALL_DIR/bin/i686-w64-mingw32-$tool.exe" "$INSTALL_DIR/bin/$tool.exe"
        fi
    fi
done

echo ""
echo "Native host binutils built successfully at: $INSTALL_DIR"
mark_done build-native-binutils
