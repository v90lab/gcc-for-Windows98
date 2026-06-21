#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-consdiag.sh - Build the consdiag.exe diagnostic for Win9x stdio
# ============================================================================
# Cross-compiles repro/diag/consdiag.c into out/extras-toolset/bin/consdiag.exe.
# Used to diagnose the busybox-w32 isatty / ansi_emulate problem on real Win98
# SE -- probes _isatty / _get_osfhandle / GetFileType / GetConsoleMode /
# GetConsoleScreenBufferInfo for fd 0/1/2 and prints what mingw_isatty would
# return after patch 0006.  Filename is 8.3-clean so it doesn't get mangled
# by command.com's short-name lookup.
#
# Standalone: msvcrt + kernel32 only.  No win98-compat shim, no busybox
# linkage.  We deliberately keep it independent so it can be run on a box
# where busybox itself is misbehaving without inheriting any of busybox's
# stdio setup.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
DIAG_SRC="$REPO_ROOT/diag/consdiag.c"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset/bin"
CROSS_BIN="$REPO_ROOT/out/toolchain/bin"
DIAG_EXE="$INSTALL_DIR/consdiag.exe"

skip_if_done build-consdiag

require_file "$DIAG_SRC" "missing consdiag source at $DIAG_SRC"
require_dir "$INSTALL_DIR" "extras-toolset/bin/ must exist (run build-native-busybox first)"
require_executable "$CROSS_BIN/${TARGET}-gcc" "cross gcc not at $CROSS_BIN/${TARGET}-gcc"

export PATH="$CROSS_BIN:$PATH"

log "compiling consdiag.exe (target=$TARGET)"
# -Os: small.  -s: strip.  Win98-safe DllCharacteristics via WIN98_TARGET_*.
# No win98-compat: this binary deliberately does NOT shim any API -- we want
# to see the raw Win9x behavior of each probed function.
# shellcheck disable=SC2086
run_logged build-consdiag.log \
    "${TARGET}-gcc" -Os -s -static -static-libgcc \
        $WIN98_TARGET_CPPFLAGS \
        $WIN98_TARGET_LDFLAGS \
        -o "$DIAG_EXE" "$DIAG_SRC"

require_file "$DIAG_EXE" "compile produced no consdiag.exe"

log "PE-verifying consdiag.exe"
# shellcheck source=verifiers/pe-win98-check.sh
source "$REPO_ROOT/scripts/verifiers/pe-win98-check.sh"
pe_check_win98 "$DIAG_EXE" || true
if [[ "$PE_CHECK_RESULT" != "pass" ]]; then
    die "consdiag.exe failed PE check: ${PE_CHECK_FAIL_REASON:-unknown}"
fi

mark_done build-consdiag
log "consdiag build complete: $DIAG_EXE"
