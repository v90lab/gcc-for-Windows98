#!/usr/bin/env bash
# smoke-bundled-pe-check.sh — End-to-end test of the cross-tarball-bundled
# pe-win98-check. Validates:
#   1. Wiring: symlink resolves, share/win98-verify/ files shipped, jq dep
#      present (jq missing → checker silently drops the per-function check
#      and may PASS a binary it should reject — caught here).
#   2. PASS path: a known-good native binary returns rc=0.
#   3. FAIL path: gdb.exe (which imports bcrypt.dll, not in the Win98
#      allowlist) returns rc=1 with a reason naming bcrypt — proves the
#      per-DLL allowlist is actually engaged. Only runs if extras is built.
#   4. Bundled-DLL escape: same gdb.exe with PE_CHECK_BUNDLED_DLLS=bcrypt.dll
#      returns rc=0 — proves the env-var override path works through the
#      packaged checker.
#
# Runs inside the consumer container (post-extraction layout).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

CROSS_PREFIX="${CROSS_PREFIX:-/opt/cross-toolset}"
CHECKER="$CROSS_PREFIX/bin/pe-win98-check"
SHARE_DIR="$CROSS_PREFIX/share/win98-verify"
ALLOWLIST="$SHARE_DIR/win98se-api-allowlist.json"
DENYLIST="$SHARE_DIR/win98-behavioral-denylist.json"

PASS=0
FAIL=0

ok()  { log "[OK]   $*"; (( PASS++ )) || true; }
bad() { log "[FAIL] $*"; (( FAIL++ )) || true; }

# ── 1. Wiring ─────────────────────────────────────────────────────────────────
log "=== Wiring ==="
[[ -L "$CHECKER" ]]   && ok "wrapper symlink: $CHECKER"        || bad "wrapper symlink missing: $CHECKER"
[[ -f "$ALLOWLIST" ]] && ok "allowlist shipped: $ALLOWLIST"    || bad "allowlist missing: $ALLOWLIST"
[[ -f "$DENYLIST"  ]] && ok "denylist shipped: $DENYLIST"      || bad "denylist missing: $DENYLIST"

if command -v jq >/dev/null 2>&1; then
    ok "jq on PATH: $(command -v jq)"
else
    bad "jq missing — per-function and behavioral-denylist checks would be skipped silently in downstream use"
fi

RESOLVED=$(command -v pe-win98-check 2>/dev/null || true)
if [[ "$RESOLVED" == "$CHECKER" ]]; then
    ok "pe-win98-check on PATH → $RESOLVED"
else
    bad "pe-win98-check PATH resolution unexpected (got: '$RESOLVED', want: '$CHECKER')"
fi

# ── 2. Acceptance path ───────────────────────────────────────────────────────
# A known-good native binary should be accepted (rc=0, [PASS] line).
log "=== checker accepts known-good binary ==="
GOOD_EXE="/opt/native-toolset/bin/gcc.exe"
if [[ -f "$GOOD_EXE" ]]; then
    if out=$("$CHECKER" "$GOOD_EXE" 2>&1); then
        ok "accepted as expected: $GOOD_EXE → $out"
    else
        bad "expected acceptance but checker returned rc=$? for $GOOD_EXE — output: $out"
    fi
else
    log "[SKIP] no $GOOD_EXE present"
fi

# ── 3. Rejection path + 4. Bundled-DLL escape ────────────────────────────────
# gdb.exe imports bcrypt.dll, which is NOT on Win98 SE (the bcrypt-shim ships
# alongside in the same directory to satisfy the import via App Directory
# search). The checker should reject it without PE_CHECK_BUNDLED_DLLS and
# accept it with PE_CHECK_BUNDLED_DLLS=bcrypt.dll.
log "=== checker rejects bcrypt-importing binary (then accepts with escape hatch) ==="
BAD_EXE="/opt/extras/bin/gdb.exe"
if [[ -f "$BAD_EXE" ]]; then
    if out=$("$CHECKER" "$BAD_EXE" 2>&1); then
        bad "expected rejection but checker accepted: $BAD_EXE → $out"
    else
        rc=$?
        if [[ "$rc" -eq 1 && "$out" == *bcrypt* ]]; then
            ok "rejected as expected: $BAD_EXE (rc=$rc, reason mentions bcrypt) → $out"
        else
            bad "rejected but with wrong rc/reason: $BAD_EXE (rc=$rc) → $out"
        fi
    fi

    if out=$(PE_CHECK_BUNDLED_DLLS=bcrypt.dll "$CHECKER" "$BAD_EXE" 2>&1); then
        ok "bundled-DLL escape works: $BAD_EXE accepted with PE_CHECK_BUNDLED_DLLS=bcrypt.dll → $out"
    else
        bad "bundled-DLL escape failed: $BAD_EXE still rejected with PE_CHECK_BUNDLED_DLLS=bcrypt.dll (rc=$?) → $out"
    fi
else
    log "[SKIP] no $BAD_EXE present (extras not built — gdb.exe rejection/escape tests skipped)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "=== Bundled PE checker: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    die "bundled pe-win98-check smoke FAILED ($FAIL items)"
fi
