#!/usr/bin/env bash
# smoke-check-native-pe.sh — Phase 2 smoke test: verify all Win32 PE binaries inside
# the native toolchain are Windows 98 compatible (no UCRT/api-ms-win imports, PE OS
# version ≤ 4.10).
# Runs inside the consumer container (/workspace = repro/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"

NATIVE="${NATIVE_PREFIX:-/opt/native-toolset}"
PASS=0
FAIL=0

check_pe_win98() {
    local exe="$1"
    local rel="${exe#$NATIVE/}"

    # `|| true` so set -e doesn't kill us on rc=1 before the case runs.
    pe_check_win98 "$exe" || true
    case "$PE_CHECK_RESULT" in
        pass)
            local ver_tag=""
            [[ -n "$PE_CHECK_OS_MAJOR" ]] && ver_tag="  OS=$PE_CHECK_OS_MAJOR.${PE_CHECK_OS_MINOR:-0}"
            log "[OK]      $rel$ver_tag"
            (( PASS++ )) || true
            ;;
        fail)
            log "[FAIL]    $rel  — $PE_CHECK_FAIL_REASON"
            (( FAIL++ )) || true
            ;;
        skip)
            log "[SKIP]    $rel  (not a PE or objdump failed)"
            ;;
    esac
}

# ── Scan native toolchain PE binaries ────────────────────────────────────────
log "=== Native toolchain Win98 PE compatibility check ==="
log "Scanning $NATIVE/bin/ ..."

if [[ ! -d "$NATIVE/bin" ]]; then
    die "Native toolchain bin directory not found: $NATIVE/bin"
fi

# Find all .exe and .dll files in the native toolchain
while IFS= read -r -d '' pe_file; do
    check_pe_win98 "$pe_file"
done < <(find "$NATIVE" -type f \( -iname "*.exe" -o -iname "*.dll" \) -print0 | sort -z)

# ── Summary ──────────────────────────────────────────────────────────────────
log "=== Native PE Win98 check: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    die "Native toolchain Win98 PE compatibility check FAILED ($FAIL files)"
fi
