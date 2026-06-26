#!/usr/bin/env bash
# smoke-tcc-build-c.sh — Phase 3e: tcc-build a curated subset of tests/smoke-c
# under wine, PE-check each output, run each under wine. Expansion of Phase 3d's
# single hello world into wider coverage: libm via msvcrt math, soft-float
# helpers from libtcc1.a, stdio file I/O, time functions, and a UCRT-absence
# probe.
#
# Driven directly (not via CMake) — tcc + CMake is a knot of toolchain-file
# compatibility issues that aren't worth untangling for a smoke pass.
#
# DEFERRED tests (kept in tests/smoke-c/ but not run by tcc until verified):
#   hello_pthread            — needs -lpthread against pthread9x; tcc's .def
#                              linkage path for pthread9x is untested.
#   thread_test              — same.
#   winsock_test             — needs -lws2_32; tcc's bundled winapi/winsock2.h
#                              may lag mingw-w64's and the .def linkage path
#                              is untested.
#   exception_test           — SEH; tcc's SEH support is partial.
#   link_compare_test        — exercises gcc-specific linker behavior.
#   win98_api_compat_test    — tests libwin98compat shim, which tcc-produced
#                              binaries don't link against (no -lwin98compat
#                              path for tcc; phase 3 work if we ever add one).
#
# Skips cleanly when tcc.exe isn't installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=verifiers/pe-win98-check.sh
source "$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"

EXTRAS="${EXTRAS_PREFIX:-/opt/extras}"
TCC="$EXTRAS/bin/tcc.exe"
TEST_SRC="/workspace/tests/smoke-c"

if [[ ! -f "$TCC" ]]; then
    log "[SKIP] tcc.exe not present at $TCC — extras package missing or built without tcc"
    exit 0
fi

require_executable wine "wine is required for the tcc-build-c smoke step"
require_dir "$TEST_SRC" "expected test sources at $TEST_SRC"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Curated tcc-safe subset. Each name corresponds to ${TEST_SRC}/<name>.c.
# Order roughly cheapest → broadest surface so failures localize.
SAFE_TESTS=(
    hello_world
    file_io_test
    time_test
    floating_point_test
    math_test
    ucrt_leak_test
    well_known_global_symbols
)

PASS_COMPILE=0; FAIL_COMPILE=0
PASS_PE=0;      FAIL_PE=0
PASS_RUN=0;     FAIL_RUN=0

log "=== tcc-built C smoke (curated subset) ==="
log "Testing ${#SAFE_TESTS[@]} programs via $TCC"

for test in "${SAFE_TESTS[@]}"; do
    src="$TEST_SRC/$test.c"
    exe="$WORK/$test.exe"

    if [[ ! -f "$src" ]]; then
        log "[MISSING] $test.c not found at $src — skipping"
        continue
    fi

    # ── Compile ──────────────────────────────────────────────────────────────
    # tcc.exe finds include/ and lib/ next to itself; no -B/-I needed. msvcrt
    # math (sin/cos/sqrt/...) is linked implicitly via tcc's win32/lib/msvcrt.def,
    # so no -lm.
    tcc_stderr="$WORK/$test.tcc.stderr"
    if ! WINEDEBUG=-all wine "$TCC" -o "$exe" "$src" 2>"$tcc_stderr"; then
        log "[FAIL-CC] $test.c — tcc compile failed"
        log "  stderr:"
        sed 's/^/    /' "$tcc_stderr" >&2 || true
        (( FAIL_COMPILE++ )) || true
        continue
    fi
    if [[ ! -f "$exe" ]]; then
        log "[FAIL-CC] $test.c — tcc returned 0 but produced no $exe"
        (( FAIL_COMPILE++ )) || true
        continue
    fi
    (( PASS_COMPILE++ )) || true

    # ── Win98 PE check ───────────────────────────────────────────────────────
    pe_check_win98 "$exe" || true
    case "$PE_CHECK_RESULT" in
        pass)
            ver_tag=""
            [[ -n "${PE_CHECK_OS_MAJOR:-}" ]] && ver_tag="  OS=$PE_CHECK_OS_MAJOR.${PE_CHECK_OS_MINOR:-0}"
            log "[OK-PE]    $test.exe$ver_tag"
            (( PASS_PE++ )) || true
            ;;
        fail)
            log "[FAIL-PE]  $test.exe — $PE_CHECK_FAIL_REASON"
            (( FAIL_PE++ )) || true
            continue   # don't waste time running a binary that's already Win98-broken
            ;;
        skip)
            log "[SKIP-PE]  $test.exe (objdump rejected the input?)"
            ;;
    esac

    # ── Wine run ─────────────────────────────────────────────────────────────
    # Treat any nonzero exit as a failure. The tests in smoke-c/ all return 0
    # on success and a nonzero status on internal assertion failure, so wine
    # rc is the right signal.
    run_out="$WORK/$test.stdout"
    run_rc=0
    WINEDEBUG=-all wine "$exe" > "$run_out" 2>&1 || run_rc=$?
    if [[ "$run_rc" -ne 0 ]]; then
        log "[FAIL-RUN] $test.exe — wine exit=$run_rc"
        log "  output:"
        sed 's/^/    /' "$run_out" >&2 || true
        (( FAIL_RUN++ )) || true
        continue
    fi
    log "[OK-RUN]   $test.exe"
    (( PASS_RUN++ )) || true
done

log "=== tcc-build-c summary ==="
log "  compile: $PASS_COMPILE passed, $FAIL_COMPILE failed"
log "  PE:      $PASS_PE passed, $FAIL_PE failed"
log "  run:     $PASS_RUN passed, $FAIL_RUN failed"

TOTAL_FAIL=$(( FAIL_COMPILE + FAIL_PE + FAIL_RUN ))
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    die "tcc-build-c smoke FAILED ($TOTAL_FAIL failures across ${#SAFE_TESTS[@]} tests)"
fi
log "=== tcc-build-c smoke PASSED ==="
