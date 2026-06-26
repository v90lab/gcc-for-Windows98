#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-httpdiag.sh - Build the httpdiag.exe Win9x TCP-listener diagnostic
# ============================================================================
# Cross-compiles repro/diag/httpdiag.c into out/extras-toolset/bin/httpdiag.exe.
# Used to verify inbound TCP connectivity on a real Win98 SE box without any
# working networking tool on the box -- listens on 0.0.0.0:8080 (or argv[1])
# by default, serves a minimal HTTP/1.0 "Hello from Win98" page, logs each
# connection to stdout.
#
# Standalone: msvcrt + kernel32 + ws2_32 only. No win98-compat shim, no
# busybox linkage. NOT wired into EXTRAS_STEPS -- build on demand:
#   docker compose exec toolchain-builder /work/scripts/build-httpdiag.sh
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
DIAG_SRC="$REPO_ROOT/diag/httpdiag.c"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset/bin"
CROSS_BIN="$REPO_ROOT/out/toolchain/bin"
DIAG_EXE="$INSTALL_DIR/httpdiag.exe"

require_file "$DIAG_SRC" "missing httpdiag source at $DIAG_SRC"
require_executable "$CROSS_BIN/${TARGET}-gcc" "cross gcc not at $CROSS_BIN/${TARGET}-gcc"

mkdir -p "$INSTALL_DIR"
export PATH="$CROSS_BIN:$PATH"

log "compiling httpdiag.exe (target=$TARGET)"
# -Os: small. -s: strip. Win98-safe DllCharacteristics via WIN98_TARGET_*.
# No win98-compat: this binary deliberately uses raw Winsock 1.1 only.
# shellcheck disable=SC2086
run_logged build-httpdiag.log \
    "${TARGET}-gcc" -Os -s -static -static-libgcc \
        $WIN98_TARGET_CPPFLAGS \
        $WIN98_TARGET_LDFLAGS \
        -o "$DIAG_EXE" "$DIAG_SRC" \
        -lws2_32

require_file "$DIAG_EXE" "compile produced no httpdiag.exe"

log "PE-verifying httpdiag.exe"
# shellcheck source=verifiers/pe-win98-check.sh
source "$REPO_ROOT/scripts/verifiers/pe-win98-check.sh"
pe_check_win98 "$DIAG_EXE" || true
if [[ "$PE_CHECK_RESULT" != "pass" ]]; then
    die "httpdiag.exe failed PE check: ${PE_CHECK_FAIL_REASON:-unknown}"
fi

log "httpdiag build complete: $DIAG_EXE"
