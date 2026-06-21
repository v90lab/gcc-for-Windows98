#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-win98-compat.sh - Build libwin98compat.a (the Win98 API shim)
# ============================================================================
# Cross-compiles repro/win98-compat/src/win98_compat.c into a static library
# and installs it (plus the public header) INTO THE CROSS-TOOLCHAIN SYSROOT
# at i686-w64-mingw32/{include,lib}. This means:
#   1. The cross-toolchain tarball (package-cross-toolset.sh tarballs the
#      whole out/toolchain tree) ships the shim for downstream consumers
#      to use when porting more software to Win98.
#   2. -lwin98compat resolves against the cross gcc's default -L search
#      paths — no -L needed.
#
# The shim works by IAT interception, not source-level macro rewriting.
# libwin98compat.a defines __imp__FOO@N slots pointing at win98_FOO
# wrappers; consumers link with `-lwin98compat` ahead of the implicit
# kernel32/ws2_32/advapi32/msvcrt import libraries and the linker resolves
# the consumer's dllimport call sites against our slots. The PE never
# imports the missing API from the real DLL. See win98_compat.c for the
# asm aliases. Consumer scripts pull -lwin98compat from WIN98_COMPAT_LDFLAGS
# in scripts/lib/common.sh; WIN98_COMPAT_CPPFLAGS is intentionally empty.
#
# What the shim covers (see src/win98_compat.c for details):
#   kernel32: GetFinalPathNameByHandleA, GetSystemWow64DirectoryA,
#             GetLogicalProcessorInformation, GetSystemTimePreciseAsFileTime,
#             IsWow64Process, GetProcessId, GetConsoleWindow, GetFileSizeEx
#   ws2_32:   getaddrinfo, freeaddrinfo, getnameinfo
#   advapi32: SystemFunction036 (RtlGenRandom)
#   msvcrt:   qsort_s
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
SHIM_SRC_DIR="$REPO_ROOT/win98-compat/src"
SHIM_INC_DIR="$REPO_ROOT/win98-compat/include"
SHIM_SRC="$SHIM_SRC_DIR/win98_compat.c"
SHIM_HDR="$SHIM_INC_DIR/win98_compat.h"
BUILD_DIR="$REPO_ROOT/build/win98-compat"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"
# Install into the cross-toolchain sysroot so `-lwin98compat` and
# `-include win98_compat.h` resolve via gcc's default search paths and
# package-cross-toolset.sh tarballs the shim alongside the toolchain.
SYSROOT_DIR="$REPO_ROOT/out/toolchain/$TARGET"
INSTALL_INC_DIR="$SYSROOT_DIR/include"
INSTALL_LIB_DIR="$SYSROOT_DIR/lib"

invalidate_if_stale build-win98-compat "$SHIM_SRC" "$SHIM_HDR"
skip_if_done build-win98-compat

require_file "$SHIM_SRC" "missing win98-compat source at $SHIM_SRC"
require_file "$SHIM_HDR" "missing win98-compat header at $SHIM_HDR"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_dir "$SYSROOT_DIR" "Cross sysroot not found at $SYSROOT_DIR (run build-cross-mingw-w64.sh first)"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

mkdir -p "$BUILD_DIR" "$INSTALL_INC_DIR" "$INSTALL_LIB_DIR"

# --- Compile -----------------------------------------------------------------
# WIN98_TARGET_CPPFLAGS pins _WIN32_WINNT=0x0400 so the shim itself doesn't
# pick up Vista+ declarations from the mingw-w64 headers; the runtime
# resolves the real signatures via GetProcAddress regardless.
log "compiling win98_compat.c"
# -Wno-cast-function-type: every shim does (fn_t)GetProcAddress(...). FARPROC's
# generic int (*)() signature differs from the real prototype, which is the
# whole point of the runtime probe. Suppressing the warning class here is
# cleaner than dancing through (void*) intermediate casts at every call site.
run_logged build-win98-compat.log \
    "$CROSS_BIN_DIR/${TARGET}-gcc" \
        -c -O2 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type \
        $WIN98_TARGET_CPPFLAGS \
        -o "$BUILD_DIR/win98_compat.o" \
        "$SHIM_SRC"

# --- Archive -----------------------------------------------------------------
log "archiving libwin98compat.a"
rm -f "$BUILD_DIR/libwin98compat.a"
run_logged build-win98-compat.log \
    "$CROSS_BIN_DIR/${TARGET}-ar" rcs \
        "$BUILD_DIR/libwin98compat.a" \
        "$BUILD_DIR/win98_compat.o"

# --- Sanity check: archive contains the redirected symbols -------------------
# Spot-check one symbol from each DLL bucket so a future source/asm-alias skew
# (e.g. someone deletes the impl but leaves the .globl in the asm block, or
# vice versa) blows up here.
log "verifying archive exports"
# Wrapper functions: nm reports them in the text section ('T'), stdcall-
# decorated as `_<sym>@<argbytes>` for WINAPI/WSAAPI or plain `_<sym>` for
# __cdecl (qsort_s). Match both with an optional @<digits> suffix.
EXPECTED_TEXT_SYMBOLS=(
    win98_GetFinalPathNameByHandleA
    win98_GetSystemWow64DirectoryA
    win98_GetLogicalProcessorInformation
    win98_getaddrinfo
    win98_SystemFunction036
    win98_qsort_s
)
# Each shimmed function FOO has TWO linker-visible aliases in the archive:
#   - __imp__FOO@N in .rdata  (IAT slot for dllimport callers)
#   - _FOO@N       in .text   (direct-call thunk for non-dllimport callers)
# Both are needed to keep the system import library (libkernel32.a /
# libws2_32.a / libadvapi32.a / libmsvcrt.a) from being pulled in for the
# shimmed symbol: missing the IAT slot lets dllimport callers leak the
# real-DLL import; missing the thunk lets non-dllimport callers (e.g.
# busybox/yescrypt declaring SystemFunction036 by hand) pull the system
# import-library .o, which ALSO redefines __imp__FOO@N and triggers a
# multiple-definition link error.
EXPECTED_INTERCEPT_NAMES=(
    GetFinalPathNameByHandleA@16
    GetSystemWow64DirectoryA@8
    GetLogicalProcessorInformation@8
    GetSystemTimePreciseAsFileTime@4
    IsWow64Process@8
    GetProcessId@4
    GetConsoleWindow@0
    GetFileSizeEx@8
    getaddrinfo@16
    freeaddrinfo@4
    getnameinfo@28
    SystemFunction036@8
    qsort_s
)
NM_OUT=$("$CROSS_BIN_DIR/${TARGET}-nm" --defined-only "$BUILD_DIR/libwin98compat.a")
for sym in "${EXPECTED_TEXT_SYMBOLS[@]}"; do
    if ! echo "$NM_OUT" | grep -qE "[[:space:]]T[[:space:]]_${sym}(@[0-9]+)?\$"; then
        echo "$NM_OUT" >&2
        die "libwin98compat.a missing wrapper symbol: $sym"
    fi
done
for name in "${EXPECTED_INTERCEPT_NAMES[@]}"; do
    decorated="${name//@/\\@}"
    # IAT slot in .rdata (R) or .data (D depending on reloc).
    if ! echo "$NM_OUT" | grep -qE "[[:space:]][RD][[:space:]]__imp__${decorated}\$"; then
        echo "$NM_OUT" >&2
        die "libwin98compat.a missing IAT interception slot: __imp__$name"
    fi
    # Direct-call thunk in .text (T).
    if ! echo "$NM_OUT" | grep -qE "[[:space:]]T[[:space:]]_${decorated}\$"; then
        echo "$NM_OUT" >&2
        die "libwin98compat.a missing direct-call thunk: _$name"
    fi
done

# --- Install -----------------------------------------------------------------
log "installing libwin98compat.a to $INSTALL_LIB_DIR and header to $INSTALL_INC_DIR"
cp "$BUILD_DIR/libwin98compat.a" "$INSTALL_LIB_DIR/libwin98compat.a"
cp "$SHIM_HDR" "$INSTALL_INC_DIR/win98_compat.h"

require_file "$INSTALL_LIB_DIR/libwin98compat.a" "libwin98compat.a install failed"
require_file "$INSTALL_INC_DIR/win98_compat.h" "win98_compat.h install failed"

mark_done build-win98-compat
log "win98-compat shim build complete"
