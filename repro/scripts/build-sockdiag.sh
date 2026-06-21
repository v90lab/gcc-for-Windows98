#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-sockdiag.sh - Build the sockdiag.exe diagnostic for Win9x Winsock
# ============================================================================
# Cross-compiles repro/diag/sockdiag.c into out/extras-toolset/bin/sockdiag.exe.
# Used to diagnose busybox-w32's wget "socket: invalid argument" failure on
# real Win98 SE -- probes 6 (BSD socket vs WSASocket) × (protocol=0 vs
# IPPROTO_TCP) × (dwFlags=0 vs WSA_FLAG_OVERLAPPED) combinations and reports
# which succeed.
#
# Standalone: msvcrt + kernel32 + ws2_32 only. No win98-compat shim, no
# busybox linkage -- we deliberately want raw Win9x Winsock behavior.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
DIAG_SRC="$REPO_ROOT/diag/sockdiag.c"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset/bin"
CROSS_BIN="$REPO_ROOT/out/toolchain/bin"
DIAG_EXE="$INSTALL_DIR/sockdiag.exe"

invalidate_if_stale build-sockdiag "$DIAG_SRC"
skip_if_done build-sockdiag

require_file "$DIAG_SRC" "missing sockdiag source at $DIAG_SRC"
require_dir "$INSTALL_DIR" "extras-toolset/bin/ must exist (run build-native-busybox first)"
require_executable "$CROSS_BIN/${TARGET}-gcc" "cross gcc not at $CROSS_BIN/${TARGET}-gcc"

export PATH="$CROSS_BIN:$PATH"

log "compiling sockdiag.exe (target=$TARGET)"
# -Os: small. -s: strip. Win98-safe DllCharacteristics via WIN98_TARGET_*.
# No win98-compat: this binary deliberately does NOT shim any API.
# shellcheck disable=SC2086
run_logged build-sockdiag.log \
    "${TARGET}-gcc" -Os -s -static -static-libgcc \
        $WIN98_TARGET_CPPFLAGS \
        $WIN98_TARGET_LDFLAGS \
        -o "$DIAG_EXE" "$DIAG_SRC" \
        -lws2_32

require_file "$DIAG_EXE" "compile produced no sockdiag.exe"

log "PE-verifying sockdiag.exe"
# shellcheck source=verifiers/pe-win98-check.sh
source "$REPO_ROOT/scripts/verifiers/pe-win98-check.sh"
pe_check_win98 "$DIAG_EXE" || true
if [[ "$PE_CHECK_RESULT" != "pass" ]]; then
    die "sockdiag.exe failed PE check: ${PE_CHECK_FAIL_REASON:-unknown}"
fi

mark_done build-sockdiag
log "sockdiag build complete: $DIAG_EXE"
