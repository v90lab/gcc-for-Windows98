#!/bin/bash
# ============================================================================
# pe-check-wine-smoke.sh — Phase 4 gate for pe-check-posix-rewrite.md
# ============================================================================
# Exercises the POSIX-sh rewrite (pe-win98-check.posix.sh) under
# wine + busybox-w32 ash against the same test cases as the existing
# smoke-bundled-pe-check.sh. Confirms the script works in its real
# deployment shell (not just bash/dash on Linux) before the Phase 5
# cutover swaps it into production.
#
# Runs inside the toolchain-builder container — that's where wine,
# busybox.exe (extras-toolset), objdump.exe (native-toolset), and
# jq.exe (extras-toolset) all coexist mid-build, without depending
# on the consumer image's extracted layout.
#
# Usage:
#
#   docker compose exec toolchain-builder \
#       /work/scripts/diag/pe-check-wine-smoke.sh
#
# Exit code: 0 if every assertion passes, 1 if any fail.
#
# Test cases (mirrors smoke-bundled-pe-check.sh §2-4):
#   1. PASS path: gcc.exe (known-good Win98-compatible binary) → rc=0
#   2. FAIL path: gdb.exe without PE_CHECK_BUNDLED_DLLS — should reject
#      for importing bcrypt.dll (not on Win98) → rc=1, reason mentions bcrypt
#   3. Bundled escape: same gdb.exe with PE_CHECK_BUNDLED_DLLS=bcrypt.dll
#      → rc=0 (App Directory search will resolve the shim)
#   4. SKIP path: non-PE file → rc=0 with [SKIP] (not a regression detector
#      but exercises the not-a-PE code path under ash)
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$PROJECT_DIR/scripts/lib/common.sh"

# Script under test — the POSIX-sh pe-check that ships to all three install
# locations (build-time sourced, cross tarball, extras toolset).
POSIX_CHECKER="$PROJECT_DIR/scripts/verifiers/pe-win98-check.sh"

# Tools we exercise the rewrite with: busybox-w32 sh as the shell, and
# native-toolset objdump.exe + extras-toolset jq.exe as the binaries the
# script invokes at runtime. All three are Windows-PE — exactly what
# the script will see on real Win98.
BUSYBOX="$PROJECT_DIR/out/extras-toolset/bin/busybox.exe"
NATIVE_BIN="$PROJECT_DIR/out/native-toolset/bin"
EXTRAS_BIN="$PROJECT_DIR/out/extras-toolset/bin"

# Test binaries.
GOOD_EXE="$NATIVE_BIN/gcc.exe"
BAD_EXE="$EXTRAS_BIN/gdb.exe"   # imports bcrypt.dll
SKIP_FILE="/etc/hostname"        # non-PE

PASS=0
FAIL=0
FAILURES=()

ok()  { log "[OK]   $*"; PASS=$((PASS + 1)); }
bad() { log "[FAIL] $*"; FAIL=$((FAIL + 1)); FAILURES+=("$*"); }

# ── Wiring sanity ────────────────────────────────────────────────────────────
log "=== Wiring ==="
require_file "$POSIX_CHECKER" "POSIX checker missing — Phase 2 deliverable not present"
require_file "$BUSYBOX"       "busybox.exe missing — extras build not run yet"
require_executable wine       "wine missing from toolchain-builder PATH"

for f in "$GOOD_EXE" "$BAD_EXE" "$SKIP_FILE"; do
    if [[ -f "$f" ]]; then
        ok "test input present: $f"
    else
        bad "test input missing: $f"
    fi
done

if [[ -f "$NATIVE_BIN/objdump.exe" ]]; then
    ok "Win-PE objdump.exe present at $NATIVE_BIN/objdump.exe"
else
    bad "Win-PE objdump.exe missing — script under test won't be able to dump anything"
fi
if [[ -f "$EXTRAS_BIN/jq.exe" ]]; then
    ok "Win-PE jq.exe present at $EXTRAS_BIN/jq.exe"
else
    bad "Win-PE jq.exe missing — per-function and denylist checks would silently degrade"
fi

if [[ $FAIL -gt 0 ]]; then
    log ""
    log "Wiring failed; aborting before exercising the checker."
    exit 1
fi

# ── Helper: invoke posix checker under wine+busybox-ash ──────────────────────
# Wine resolves Linux paths under drive Z: by default, so busybox-under-wine
# sees /work/... as Z:\work\.... PATH inside that shell must point at the
# Win-PE objdump and jq (the Linux ones are ELF; busybox-under-wine can't
# exec them).
wine_check() {
    local extra_env=$1
    local target=$2

    wine "$BUSYBOX" sh -c "
        export PATH=$EXTRAS_BIN:$NATIVE_BIN:\$PATH
        ${extra_env:+export $extra_env;}
        $POSIX_CHECKER '$target'
    " 2>&1
}

# ── Assertion helper ─────────────────────────────────────────────────────────
# Runs wine_check, captures rc + output, checks rc matches expectation
# and output contains the substring. Both conditions must hold for OK.
assert_check() {
    local label=$1
    local expected_rc=$2
    local expected_substr=$3
    local extra_env=$4
    local target=$5

    local out rc
    out=$(wine_check "$extra_env" "$target")
    rc=$?

    if [[ "$rc" != "$expected_rc" ]]; then
        bad "$label: expected rc=$expected_rc, got rc=$rc — out: $out"
        return 1
    fi
    if [[ "$out" != *"$expected_substr"* ]]; then
        bad "$label: expected substring '$expected_substr' not in output — out: $out"
        return 1
    fi
    ok "$label (rc=$rc, contains '$expected_substr')"
}

# ── Test 1: PASS path ────────────────────────────────────────────────────────
log ""
log "=== Test 1: PASS path (known-good native binary) ==="
assert_check \
    "gcc.exe accepted" \
    0 \
    "[PASS]" \
    "" \
    "$GOOD_EXE" || true

# ── Test 2: FAIL path ────────────────────────────────────────────────────────
log ""
log "=== Test 2: FAIL path (gdb.exe imports bcrypt.dll, no bundling) ==="
assert_check \
    "gdb.exe rejected for bcrypt.dll" \
    1 \
    "bcrypt" \
    "" \
    "$BAD_EXE" || true

# ── Test 3: Bundled escape ───────────────────────────────────────────────────
log ""
log "=== Test 3: Bundled escape (gdb.exe + PE_CHECK_BUNDLED_DLLS=bcrypt.dll) ==="
assert_check \
    "gdb.exe accepted with bundled bcrypt.dll" \
    0 \
    "[PASS]" \
    "PE_CHECK_BUNDLED_DLLS=bcrypt.dll" \
    "$BAD_EXE" || true

# ── Test 4: SKIP path ────────────────────────────────────────────────────────
log ""
log "=== Test 4: SKIP path (non-PE file) ==="
assert_check \
    "non-PE file produces [SKIP]" \
    0 \
    "[SKIP]" \
    "" \
    "$SKIP_FILE" || true

# ── Summary ──────────────────────────────────────────────────────────────────
log ""
log "=== Summary ==="
log "  PASS: $PASS"
log "  FAIL: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    log ""
    log "Failed assertions:"
    for f in "${FAILURES[@]}"; do
        log "  - $f"
    done
    exit 1
fi

log ""
log "All wine+busybox-ash assertions passed. Phase 5 cutover is gated green."
exit 0
