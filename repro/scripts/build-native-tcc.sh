#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-tcc.sh - Build tinycc (tcc) for the extras toolset
# ============================================================================
# Cross-compiles tinycc from the upstream mob branch into a Win98-hosted
# i386 PE. tcc has a tiny shell `configure` (no autoconf, no bootstrap) and
# a Makefile-driven build; the upstream docs explicitly support
# `--cross-prefix=i686-w64-mingw32-` (win32/tcc-win32.txt §"Compilation from
# source"), so we follow that path.
#
# Risk surface on the host binary (tcc.exe itself) is small: KERNEL32 +
# msvcrt only, and the one Vista+ API call site (AddVectoredExceptionHandler
# in tccrun.c) is dead under `#ifdef _WIN64`. tcc.h hardcodes
# _WIN32_WINNT=0x502 to surface that API's declaration; we override to
# 0x0400 via WIN98_TARGET_CPPFLAGS as belt-and-suspenders.
#
# libtcc1.a (the target-side runtime archive) is built by running tcc.exe
# itself against lib/*.c — on Linux we wrap that invocation with wine. tcc's
# lib/Makefile uses tcc-as-archiver too (`$(XTCC) -ar`), so the single XTCC
# override covers compile + archive steps.
#
# In-package layout (under $INSTALL_DIR/bin/):
#   tcc.exe              <- the compiler
#   include/             <- tcc-target headers (its bundled minimal mingw set)
#   lib/                 <- libtcc1.a + win32/lib/*.def import descriptors
#   libtcc/libtcc.{a,h}  <- libtcc embedding API for JIT users
# tcc resolves its tccdir at runtime as dirname(tcc.exe) on Win32, so all
# resources sit next to the executable rather than under a separate prefix.
# include/ and lib/ as siblings of tcc.exe inside bin/ is unconventional but
# self-contained: nothing else in the extras package writes there.
#
# Phase-2 work (binaries tcc PRODUCES being Win98-clean) is a separate audit
# pass over tccpe.c + bundled CRT (win32/lib/crt1.c etc.) + bundled headers.
# That's not done here — this script only ensures tcc.exe itself runs.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
TCC_SRC="$REPO_ROOT/src/tinycc"
BUILD_DIR="$REPO_ROOT/build/tcc-native-host"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-native-tcc

# === STEP 1: Verify prerequisites ===
require_dir "$TCC_SRC" "Missing tcc sources at $TCC_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"
require_executable wine "wine is required (libtcc1.a step needs to run tcc.exe under wine)"

export PATH="$CROSS_BIN_DIR:$PATH"

# tcc's configure mangles ccache wrapping. It applies cross-prefix as a
# string prepend on `$CC` (configure line ~298: `cc="${cross_prefix}${cc}"`),
# which turns "ccache i686-w64-mingw32-gcc" into the nonsense command
# "i686-w64-mingw32-ccache i686-w64-mingw32-gcc". Even without
# --cross-prefix, configure still picks up CC from the environment via
# common.sh's defaults. Drop ccache for this build — tcc is small
# (~15k LoC, single binary) so the savings are negligible — and pass
# --cc/--ar explicitly to configure below.
unset CC CXX

# === STEP 2: Configure (out-of-tree) ===
# tcc's configure writes config.mak into cwd, so we run it from $BUILD_DIR
# with --source-path pointing at $TCC_SRC. Configure auto-detects build_cross
# from cross_prefix being set (and skips the conftest run-test that fails for
# cross builds, see configure §"check for crpss build").
#
# Flags:
#   --cpu=i386 + --targetos=WIN32 select NATIVE_TARGET=i386-win32 (DEF-i386-win32
#     adds -DTCC_TARGET_I386 -DTCC_TARGET_PE in the Makefile). cpu != cpu_sys
#     (i386 vs x86_64) is enough to set configure's build_cross=yes on its own,
#     so we don't need --cross-prefix (which would mangle ccache wrapping).
#   --cc/--ar wire our cross gcc/ar explicitly.
#   --enable-static avoids libtcc.dll so we ship libtcc.a only — no DLL
#     dependency on Win98.
#   --config-predefs=no disables the c2str.exe code path. tcc bakes
#     include/tccdefs.h into the compiler at build time by running a tiny
#     helper (`c2str.exe`, cross-compiled) against the header. Cross-built
#     it's a Win32 PE that can't run on Linux, and there's no clean way
#     to wine-wrap a $S./c2str.exe recipe inside the Makefile. With
#     predefs=no, tccpp.c falls back to `#include <tccdefs.h>` at runtime
#     (tccpp.c:3625-3629), which our install step ships in include/.
#     Matches what the upstream build-tcc.bat does — the c2str.exe lines
#     there are commented out for the same reason.
#   --prefix doubles as bindir/tccdir/libdir on Win32 (configure block at
#     line 414-419 collapses them all to prefix). Pointing it at
#     $INSTALL_DIR/bin keeps tcc's runtime-detected tccdir (dirname of the
#     running tcc.exe) consistent with where we install its resources.
#   --extra-cflags / --extra-ldflags fold Win98 + compat shim flags into
#     config.mak. _WIN32_WINNT=0x0400 redundantly lowers what tcc.h:55-56
#     hardcodes to 0x502 (defensive — the only API gated by it lives under
#     #ifdef _WIN64 and is dead on i386).
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

log "configuring tinycc for $TARGET (Win98 host)"
run_logged build-native-tcc.log "$TCC_SRC/configure" \
    --source-path="$TCC_SRC" \
    --cpu=i386 \
    --targetos=WIN32 \
    --cc="${TARGET}-gcc" \
    --ar="${TARGET}-ar" \
    --prefix="$INSTALL_DIR/bin" \
    --enable-static \
    --config-predefs=no \
    --extra-cflags="$WIN98_TARGET_CPPFLAGS $WIN98_COMPAT_CPPFLAGS -D_WIN32_WINNT=0x0400" \
    --extra-ldflags="-static-libgcc $WIN98_TARGET_LDFLAGS $WIN98_COMPAT_LDFLAGS"

# === STEP 3: Build tcc.exe + libtcc.a ===
# These build with the cross gcc directly — no wine needed. Targets are
# explicit so we don't pay for tcc-doc.html / tcc-doc.info / tcc.1 (which
# need makeinfo / pod2man we don't ship).
log "building tcc.exe + libtcc.a"
run_logged build-native-tcc.log make -j"$JOBS" tcc.exe libtcc.a

# === STEP 4: Build libtcc1.a via wine-wrapped tcc.exe ===
# lib/Makefile compiles each lib/*.c (and *.S) by invoking tcc.exe against it.
# On Linux we shim that call through wine. XTCC is the override knob: XCC
# defaults to XTCC for compiles, and XAR defaults to `$(XTCC) -ar` for the
# archive step, so a single override covers both.
WINE_TCC="$BUILD_DIR/wine-tcc.sh"
cat > "$WINE_TCC" <<EOF
#!/bin/sh
exec wine "$BUILD_DIR/tcc.exe" "\$@"
EOF
chmod +x "$WINE_TCC"

log "building libtcc1.a (wine-wrapped tcc.exe)"
# Single-job for libtcc1.a — the lib/Makefile sub-make includes the top
# Makefile and the parallel-make hazard around c2str.exe / tccdefs_.h would
# otherwise need a tcc-friendly serialization (see the upstream rule
# comment at Makefile:274-279). Single-job here costs only the runtime of
# ~20 small lib/*.c compiles.
run_logged build-native-tcc.log make libtcc1.a XTCC="$WINE_TCC"

# === STEP 5: PE verify tcc.exe ===
log "running Win98 PE check on tcc.exe"
# shellcheck source=verifiers/pe-win98-check.sh
source "$REPO_ROOT/scripts/verifiers/pe-win98-check.sh"
pe_check_win98 "$BUILD_DIR/tcc.exe" || true
if [[ "$PE_CHECK_RESULT" != "pass" ]]; then
    die "tcc.exe failed Win98 PE check: $PE_CHECK_FAIL_REASON"
fi

# === STEP 6: Install ===
# `make install` would call into install-win in the Makefile, which assumes
# a Windows-host install layout (BINDIR == TCCDIR, everything next to
# tcc.exe). Our extras package puts tcc.exe in bin/ next to other tools, so
# we manually copy what we need into a self-contained tree under bin/.
INSTALL_BIN="$INSTALL_DIR/bin"
TCC_RES="$INSTALL_BIN"  # tcc resolves tccdir = dirname(tcc.exe) on Win32
mkdir -p "$INSTALL_BIN" "$TCC_RES/include" "$TCC_RES/lib" "$TCC_RES/libtcc"

# Compiler
cp "$BUILD_DIR/tcc.exe" "$INSTALL_BIN/tcc.exe"

# Target headers — tcc's bundled minimal-mingw replacement plus the libc-style
# headers shared across all targets and tcclib.h (for `tcc -run` programs).
cp -r "$TCC_SRC/win32/include/." "$TCC_RES/include/"
cp "$TCC_SRC/include/"*.h "$TCC_RES/include/"
cp "$TCC_SRC/tcclib.h" "$TCC_RES/include/"

# Target runtime + CRT/system import descriptors. tcc resolves -lkernel32
# etc. against these .def files (not .a import libs).
cp "$BUILD_DIR/libtcc1.a" "$TCC_RES/lib/"
cp "$TCC_SRC/win32/lib/"*.def "$TCC_RES/lib/"

# libtcc embedding API for JIT users (`#include <libtcc.h>` + link
# -ltcc against libtcc.a).
cp "$BUILD_DIR/libtcc.a" "$TCC_RES/libtcc/libtcc.a"
cp "$TCC_SRC/libtcc.h" "$TCC_RES/libtcc/libtcc.h"

require_file "$INSTALL_BIN/tcc.exe" "tcc install produced no tcc.exe"
require_file "$TCC_RES/lib/libtcc1.a" "tcc install produced no libtcc1.a"

mark_done build-native-tcc
log "tinycc build complete"
