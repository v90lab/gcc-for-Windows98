#!/usr/bin/env bash
# smoke-check-extras-pe.sh — verify that every PE binary inside the extras toolset
# is Windows 98 compatible (no UCRT / api-ms-win / vcruntime imports,
# MajorOSVersion ≤ 4).
#
# Runs inside the consumer container; mirrors smoke-check-native-pe.sh but
# targets /opt/extras (EXTRAS_PREFIX). If the extras prefix is empty —
# which happens when the build pipeline skipped extras via BUILD_EXTRAS=0
# — the check exits cleanly with a skip notice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"

EXTRAS="${EXTRAS_PREFIX:-/opt/extras}"
PASS=0
FAIL=0

# bcrypt.dll is shipped as a bundled shim alongside gdb.exe — see
# verify-extras-package.sh for the rationale.
export PE_CHECK_BUNDLED_DLLS="bcrypt.dll"

check_pe_win98() {
    local exe="$1"
    local rel="${exe#"$EXTRAS"/}"

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

log "=== Extras toolset Win98 PE compatibility check ==="
log "Scanning $EXTRAS/bin/ ..."

if [[ ! -d "$EXTRAS/bin" ]] || [[ -z "$(find "$EXTRAS" -type f \( -iname '*.exe' -o -iname '*.dll' \) -print -quit)" ]]; then
    log "[SKIP] no extras binaries present at $EXTRAS — pipeline likely ran with BUILD_EXTRAS=0"
    exit 0
fi

while IFS= read -r -d '' pe_file; do
    check_pe_win98 "$pe_file"
done < <(find "$EXTRAS" -type f \( -iname "*.exe" -o -iname "*.dll" \) -print0 | sort -z)

log "=== Extras PE Win98 check: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    die "Extras toolset Win98 PE compatibility check FAILED ($FAIL files)"
fi
