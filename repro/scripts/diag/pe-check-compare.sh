#!/bin/bash
# ============================================================================
# pe-check-compare.sh — Phase 3 deliverable for pe-check-posix-rewrite.md
# ============================================================================
# Walks all .exe and .dll under the native + extras + toolchain trees, runs
# BOTH pe-win98-check.sh (bash original) and pe-win98-check.posix.sh (POSIX
# sh rewrite) against each, and reports any divergence in CLI output or rc.
#
# Exit code: 0 if every binary's old-output == new-output, 1 if any
# divergence found.
#
# Usage (from inside toolchain-builder, or via docker compose exec):
#
#   ./scripts/diag/pe-check-compare.sh                       # default scan
#   ./scripts/diag/pe-check-compare.sh --no-bundled          # FAIL surface
#   ./scripts/diag/pe-check-compare.sh --filter 'g*.exe'     # subset
#   ./scripts/diag/pe-check-compare.sh --verbose             # show OK rows
#   ./scripts/diag/pe-check-compare.sh path/to/foo.exe       # explicit list
#
# Acceptance: zero MISMATCH rows for both `--bundled bcrypt.dll` (default,
# matches production verify) AND `--no-bundled` (the explicit FAIL surface
# where gdb.exe correctly rejects bcrypt.dll). Run both as part of the
# Phase 3 gate.
#
# This is a diagnostic — full bash, not POSIX sh. The thing under test is
# POSIX; the tester can use any features it likes.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Script lives at scripts/diag/ — go up TWO levels to reach repro/.
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

OLD_CHECKER="$PROJECT_DIR/scripts/verifiers/pe-win98-check.sh"
NEW_CHECKER="$PROJECT_DIR/scripts/verifiers/pe-win98-check.posix.sh"

# --- Defaults ---------------------------------------------------------------
DEFAULT_SCAN_DIRS=(
    "$PROJECT_DIR/out/native-toolset"
    "$PROJECT_DIR/out/extras-toolset"
    "$PROJECT_DIR/out/toolchain"
)
BUNDLED_DLLS="bcrypt.dll"
IGNORE_REASON_ORDER=0
FILTER=""
VERBOSE=0
SCAN_DIRS=()
EXPLICIT_BINS=()

usage() {
    sed -n '/^# ===/,/^# ===/p' "$0" | sed 's/^# *//'
    exit "${1:-0}"
}

# --- Arg parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-bundled)         BUNDLED_DLLS=""; shift ;;
        --bundled)            BUNDLED_DLLS="$2"; shift 2 ;;
        --ignore-reason-order) IGNORE_REASON_ORDER=1; shift ;;
        --scan)               SCAN_DIRS+=("$2"); shift 2 ;;
        --filter)             FILTER="$2"; shift 2 ;;
        --verbose|-v)         VERBOSE=1; shift ;;
        --help|-h)            usage 0 ;;
        --)                   shift; EXPLICIT_BINS+=("$@"); break ;;
        -*)                   echo "Unknown option: $1" >&2; usage 1 ;;
        *)                    EXPLICIT_BINS+=("$1"); shift ;;
    esac
done

[[ ${#SCAN_DIRS[@]} -eq 0 ]] && SCAN_DIRS=("${DEFAULT_SCAN_DIRS[@]}")

# --- Tool sanity -------------------------------------------------------------
[[ -x "$OLD_CHECKER" ]] || { echo "missing or not executable: $OLD_CHECKER" >&2; exit 2; }
[[ -x "$NEW_CHECKER" ]] || { echo "missing or not executable: $NEW_CHECKER" >&2; exit 2; }

# --- Build the binary list ---------------------------------------------------
declare -a BINARIES
if [[ ${#EXPLICIT_BINS[@]} -gt 0 ]]; then
    BINARIES=("${EXPLICIT_BINS[@]}")
else
    while IFS= read -r -d '' f; do
        BINARIES+=("$f")
    done < <(
        for d in "${SCAN_DIRS[@]}"; do
            [[ -d "$d" ]] || continue
            # Include .exe, .dll, AND extension-less executables (cross
            # toolchain Linux ELFs). Both checkers should SKIP non-PE,
            # confirming the SKIP-path stays equivalent.
            find "$d" -type f \( -name '*.exe' -o -name '*.dll' -o ! -name '*.*' \) -print0
        done
    )
fi

# Filter by glob (matches against basename)
if [[ -n "$FILTER" ]]; then
    declare -a FILTERED
    for b in "${BINARIES[@]}"; do
        # shellcheck disable=SC2053
        [[ "$(basename "$b")" == $FILTER ]] && FILTERED+=("$b")
    done
    BINARIES=("${FILTERED[@]}")
fi

# Deterministic order
IFS=$'\n' read -r -d '' -a BINARIES < <(printf '%s\n' "${BINARIES[@]}" | LC_ALL=C sort && printf '\0')

if [[ ${#BINARIES[@]} -eq 0 ]]; then
    echo "No binaries matched. Scan dirs: ${SCAN_DIRS[*]} Filter: '$FILTER'" >&2
    exit 2
fi

# --- Output canonicalization (for --ignore-reason-order) --------------------
# A FAIL line looks like:
#   [FAIL] <path> — r1; r2; r3
# Canonicalize by sorting r1..rN alphabetically. Other lines pass through.
canonicalize_output() {
    local line
    while IFS= read -r line; do
        case "$line" in
            '[FAIL] '*' — '*)
                local prefix=${line%% — *}
                local reasons=${line#* — }
                local sorted
                sorted=$(printf '%s\n' "$reasons" \
                    | tr ';' '\n' \
                    | sed 's/^ *//;s/ *$//' \
                    | LC_ALL=C sort \
                    | paste -sd';' -)
                printf '%s — %s\n' "$prefix" "$sorted"
                ;;
            *) printf '%s\n' "$line" ;;
        esac
    done
}

# --- Per-binary check -------------------------------------------------------
ok_count=0
mismatch_count=0
declare -a MISMATCHES

cat <<EOF
=== pe-check-compare ===
  OLD:     $OLD_CHECKER
  NEW:     $NEW_CHECKER
  Bundled: ${BUNDLED_DLLS:-<unset>}
  IgnoreOrder: $IGNORE_REASON_ORDER
  Total binaries: ${#BINARIES[@]}

EOF

for bin in "${BINARIES[@]}"; do
    [[ -f "$bin" ]] || continue

    old_out=$(PE_CHECK_BUNDLED_DLLS="$BUNDLED_DLLS" "$OLD_CHECKER" "$bin" 2>&1)
    old_rc=$?
    new_out=$(PE_CHECK_BUNDLED_DLLS="$BUNDLED_DLLS" "$NEW_CHECKER" "$bin" 2>&1)
    new_rc=$?

    if [[ "$old_rc" == "$new_rc" && "$old_out" == "$new_out" ]]; then
        ok_count=$((ok_count + 1))
        [[ $VERBOSE == 1 ]] && printf '[OK]       %s\n' "$bin"
        continue
    fi

    # If only the order of failure reasons differs, treat as match (when
    # the flag is on). Same-rc + canonicalized output == match.
    if [[ $IGNORE_REASON_ORDER == 1 && "$old_rc" == "$new_rc" ]]; then
        old_canon=$(printf '%s\n' "$old_out" | canonicalize_output)
        new_canon=$(printf '%s\n' "$new_out" | canonicalize_output)
        if [[ "$old_canon" == "$new_canon" ]]; then
            ok_count=$((ok_count + 1))
            [[ $VERBOSE == 1 ]] && printf '[OK*]      %s (reason-order differs but set equal)\n' "$bin"
            continue
        fi
    fi

    mismatch_count=$((mismatch_count + 1))
    printf '[MISMATCH] %s\n' "$bin"
    printf '           OLD (rc=%d): %s\n' "$old_rc" "$old_out"
    printf '           NEW (rc=%d): %s\n' "$new_rc" "$new_out"
    MISMATCHES+=("$bin")
done

# --- Summary ----------------------------------------------------------------
printf '\n=== Summary ===\n'
printf '  Scanned:   %d\n' "$((ok_count + mismatch_count))"
printf '  OK:        %d\n' "$ok_count"
printf '  MISMATCH:  %d\n' "$mismatch_count"

if [[ $mismatch_count -gt 0 ]]; then
    printf '\n  MISMATCHED binaries:\n'
    for m in "${MISMATCHES[@]}"; do
        printf '    %s\n' "$m"
    done
    exit 1
fi

printf '\n  All binaries produce identical output between old and new.\n'
exit 0
