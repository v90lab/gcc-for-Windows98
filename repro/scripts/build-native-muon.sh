#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-muon.sh - Build muon (C99 meson implementation)
# ============================================================================
# Uses upstream Python meson + ninja from the builder image to cross-compile
# muon for i686-w64-mingw32. muon's source tree ships meson.build files, so
# meson can configure and ninja can build it directly — bypassing muon's
# own two-stage bootstrap (whose minimal CLI does not support --cross-file).
#
# This is a stretch goal — see Agents.md context. The script is intentionally
# NOT wired into EXTRAS_STEPS yet; run it manually:
#
#   docker compose -f docker-compose.yml exec toolchain-builder \
#     bash /work/scripts/build-native-muon.sh
#
# When it builds cleanly we'll add the EXTRAS_STEPS line and the
# verify/status/smoke/manifest wiring.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
MUON_SRC="$REPO_ROOT/src/muon"
BUILD_DIR="$REPO_ROOT/build/muon-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-muon

# === STEP 1: Verify prerequisites ===
require_dir "$MUON_SRC" "Missing muon sources at $MUON_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"
require_executable meson "meson not installed in builder (apt install meson)"
require_executable ninja "ninja not installed in builder (apt install ninja-build)"

# === STEP 1b: Patch muon for Win98 target ===
# filesystem.c — the MSYS/mintty pipe-detection block in fs_is_a_tty_from_fd
# uses FILE_NAME_INFO and GetFileInformationByHandleEx, which mingw-w64 only
# exposes when _WIN32_WINNT >= 0x0600 (Vista+). Our WIN98_TARGET_CPPFLAGS
# sets _WIN32_WINNT=0x0400 so the headers hide them. Gate the block on
# _WIN32_WINNT >= 0x0600 — on Win98 there's no MSYS/Cygwin pty to detect
# anyway, and the function falls through to GetConsoleMode for cmd.exe-style
# ttys.
#
# Note: os.c (os_ncpus / GetLogicalProcessorInformation) used to be patched
# here too. The Win98 compat shim (libwin98compat.a, force-included via
# WIN98_COMPAT_CPPFLAGS) now macro-redirects GetLogicalProcessorInformation
# to a wrapper that GetProcAddress-probes and falls back to GetSystemInfo
# on Win9x. See repro/win98-compat/.
log "patching muon filesystem.c for Win98 target"
python3 - "$MUON_SRC/src/platform/windows/filesystem.c" <<'PATCH_EOF'
import sys
path = sys.argv[1]
src = open(path).read()
marker = "#if _WIN32_WINNT >= 0x0600 /* win98: mintty pipe-detection */"
if marker in src:
    sys.exit(0)
anchor = ("\t/*\n"
          "\t * test if the stream is associated to a mintty-based terminal\n")
i = src.find(anchor)
assert i >= 0, "muon mintty-block anchor not found"
brace_start = src.find("\t{\n", i)
assert brace_start >= 0, "muon mintty open brace not found"
depth = 0
j = brace_start
while j < len(src):
    c = src[j]
    if c == '{':
        depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0:
            close_end = j + 1
            break
    j += 1
else:
    raise SystemExit("muon mintty close brace not found")
new = (src[:brace_start]
       + marker + "\n"
       + src[brace_start:close_end]
       + "\n#endif"
       + src[close_end:])
open(path, "w").write(new)
PATCH_EOF

mkdir -p "$BUILD_DIR"

# === STEP 2: Cross file ===
# Meson cross file pointing at our mingw cross toolchain. needs_exe_wrapper
# tells meson not to try executing produced binaries on the build host.
# [built-in options] propagates the Win98 host CPPFLAGS/LDFLAGS through
# meson into every compile + link unit muon's build emits.
CROSS_FILE="$BUILD_DIR/mingw32.cross.ini"

_meson_array() {
    # Turn "a b c" into ['a', 'b', 'c'] for meson cross-file syntax.
    local out="[" first=1 word
    for word in "$@"; do
        [[ $first -eq 0 ]] && out+=", "
        out+="'$word'"
        first=0
    done
    out+="]"
    printf '%s\n' "$out"
}
# shellcheck disable=SC2086 # intentional word-splitting on the flag strings
CPPFLAGS_ARRAY=$(_meson_array $WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS)
# shellcheck disable=SC2086
LDFLAGS_ARRAY=$(_meson_array $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS)

cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$CROSS_BIN_DIR/${TARGET}-gcc'
cpp = '$CROSS_BIN_DIR/${TARGET}-g++'
ar = '$CROSS_BIN_DIR/${TARGET}-ar'
strip = '$CROSS_BIN_DIR/${TARGET}-strip'
windres = '$CROSS_BIN_DIR/${TARGET}-windres'

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = $CPPFLAGS_ARRAY
c_link_args = $LDFLAGS_ARRAY
cpp_args = $CPPFLAGS_ARRAY
cpp_link_args = $LDFLAGS_ARRAY
EOF

# === STEP 3: Configure ===
# Keep samurai embedded (so muon.exe doesn't need an external ninja on
# Win98) and readline=builtin (bestline, no system libreadline required).
# Disable everything else that depends on libraries we don't have on Win98.
CROSS_BUILD_DIR="$BUILD_DIR/cross"
rm -rf "$CROSS_BUILD_DIR"

export PATH="$CROSS_BIN_DIR:$PATH"

log "configuring muon cross-build for $TARGET"
# --buildtype=release: meson defaults to `debug` (-O0 -g) which leaves muon
# unoptimized and -DMUON_RELEASE=0 (extra assertions/logging in muon's own
# code). Release gives -O3 -DNDEBUG and flips MUON_RELEASE=1. The autoconf
# tools on either side of this all bake in -g -O2 by default, so muon was
# the only shipped binary running at -O0 — caught after the strip-toolset
# pass made the size comparison stark.
run_logged build-native-muon.log meson setup \
    --cross-file "$CROSS_FILE" \
    --prefix "$INSTALL_DIR" \
    --buildtype=release \
    -Dstatic=true \
    -Dsamurai=enabled \
    -Dreadline=builtin \
    -Dlibcurl=disabled \
    -Dlibarchive=disabled \
    -Dlibpkgconf=disabled \
    -Dtracy=disabled \
    -Dnative_backtrace=disabled \
    -Dman-pages=disabled \
    -Dmeson-docs=disabled \
    -Dmeson-tests=disabled \
    -Dwebsite=disabled \
    "$CROSS_BUILD_DIR" "$MUON_SRC"

# === STEP 4: Build ===
log "building muon for $TARGET"
run_logged build-native-muon.log ninja -C "$CROSS_BUILD_DIR"

# === STEP 5: Install ===
# meson install would try to honor a DESTDIR-style install and may want to
# run the cross-built binaries — skip it and copy muon.exe directly.
log "installing muon to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin"
cp "$CROSS_BUILD_DIR/muon.exe" "$INSTALL_DIR/bin/muon.exe"

require_file "$INSTALL_DIR/bin/muon.exe" "muon install produced no muon.exe"

mark_done build-native-muon
log "muon build complete"
