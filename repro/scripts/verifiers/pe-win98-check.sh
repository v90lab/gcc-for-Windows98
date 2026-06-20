#!/usr/bin/env bash
# ============================================================================
# pe-win98-check.sh — Shared Win98 PE compatibility checker
# ============================================================================
# Can be SOURCED by other scripts or CALLED directly as a CLI tool.
#
# When sourced, provides:
#   pe_check_win98 <exe>
#     Inspects the PE binary at <exe> using objdump.
#     Returns:
#       0  — Win98 compatible
#       1  — incompatible (sets PE_CHECK_FAIL_REASON)
#       2  — not a PE / objdump failed (skip)
#     Sets these variables on every call:
#       PE_CHECK_RESULT       "pass" | "fail" | "skip"
#       PE_CHECK_FAIL_REASON  human-readable failure description (non-empty on fail)
#       PE_CHECK_BAD_IMPORT   the offending DLL name (non-empty if DLL-level failure)
#       PE_CHECK_BAD_FUNCTION the offending DLL:function (non-empty if import-level failure)
#       PE_CHECK_BAD_KIND     "missing" if the function isn't in the allowlist,
#                             "denied"  if it's in the allowlist but on the
#                                       behavioral denylist (stub-only on Win98)
#       PE_CHECK_OS_MAJOR     MajorOSVersion integer (empty if not found)
#       PE_CHECK_OS_MINOR     MinorOSVersion integer (empty if not found)
#       PE_CHECK_SUBSYS_MAJOR MajorSubsystemVersion integer (empty if not found)
#       PE_CHECK_SUBSYS_MINOR MinorSubsystemVersion integer (empty if not found)
#
#   PE_FORBIDDEN_IMPORT_PATTERNS
#     Array of lower-case substring patterns that must not appear in DLL imports.
#
# When called directly:
#   pe-win98-check.sh <exe> [<exe2> ...]
#   Exit 0 if all pass; 1 if any fail.
#
# Per-import allowlist:
#   The Win98 system DLL export surface lives at
#   repro/data/win98se-api-allowlist.json (generated from a real Win98 SE
#   install by scripts/utils/generate-win98-api-allowlist.py). When that
#   file is present and jq is available, the checker also rejects:
#     * imports from any DLL that isn't in the snapshot (e.g. bcrypt.dll)
#     * function imports not present in the snapshot DLL's export table
#       (e.g. kernel32!GetFileInformationByHandleEx)
#   Set PE_CHECK_ALLOWLIST to override the path; set PE_CHECK_ALLOWLIST=""
#   to disable the per-function check (the DLL-substring + OS-version checks
#   still run).
#
# Behavioral denylist:
#   Some symbols in the allowlist (especially advapi32 NT-security APIs)
#   exist in Win98 SE's export table as stubs that always return failure on
#   the Win9x kernel. They bind cleanly at PE load time but are non-functional
#   at runtime. The denylist at repro/data/win98-behavioral-denylist.json
#   names those — any symbol listed there is rejected even though the
#   allowlist accepts it. PE_CHECK_FAIL_REASON for these reads "Win98
#   stub-only (binds but non-functional)". Set PE_CHECK_DENYLIST="" to
#   disable, or override the path.
#
# Bundled-DLL exception:
#   PE_CHECK_BUNDLED_DLLS — space-separated list of DLL basenames (case-
#   insensitive, e.g. "bcrypt.dll") that should be treated as if shipped
#   in the same package as the binary under test. Imports from those DLLs
#   skip both the "is this DLL on Win98?" check and the per-function
#   export-table check. Use this for shims (e.g. our bcrypt.dll
#   BCryptGenRandom stub) that satisfy a dynamic-link dependency the
#   loader's App Directory search will resolve at runtime.
# ============================================================================

# DLL name substrings (lower-cased) that must not appear in PE import tables.
PE_FORBIDDEN_IMPORT_PATTERNS=(
    "api-ms-win-"
    "ucrtbase.dll"
    "vcruntime"
)

# Resolve the allowlist + denylist JSON. Two supported layouts:
#   * Repo layout:           repro/scripts/verifiers/pe-win98-check.sh
#                            repro/data/{allowlist,denylist}.json
#                            (data resolves at $self/../../data/)
#   * Flat installed layout: $toolchain/share/win98-verify/pe-win98-check.sh
#                            $toolchain/share/win98-verify/{allowlist,denylist}.json
#                            (data sits next to the script)
# The repo layout is tried first so in-tree behavior is unchanged; the flat
# layout is the fallback used by the cross-toolchain bundle. PE_CHECK_ALLOWLIST
# / PE_CHECK_DENYLIST still override both.
_pe_check_resolve_data() {
    local basename="$1"
    local self_dir
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$self_dir/../../data/$basename" ]]; then
        printf '%s\n' "$self_dir/../../data/$basename"
        return
    fi
    if [[ -f "$self_dir/$basename" ]]; then
        printf '%s\n' "$self_dir/$basename"
        return
    fi
    # Nothing found — return the repo-relative path so error messages stay
    # readable. The caller falls through to a degraded mode when the file
    # doesn't exist anyway.
    printf '%s\n' "$self_dir/../../data/$basename"
}

_pe_check_default_allowlist() {
    _pe_check_resolve_data "win98se-api-allowlist.json"
}

_pe_check_default_denylist() {
    _pe_check_resolve_data "win98-behavioral-denylist.json"
}

: "${PE_CHECK_ALLOWLIST=$(_pe_check_default_allowlist)}"
: "${PE_CHECK_DENYLIST=$(_pe_check_default_denylist)}"

# pe_check_win98 <exe>
# See header for return values and variable side-effects.
pe_check_win98() {
    local exe="$1"

    # Reset output variables.
    PE_CHECK_RESULT=""
    PE_CHECK_FAIL_REASON=""
    PE_CHECK_BAD_IMPORT=""
    PE_CHECK_BAD_FUNCTION=""
    PE_CHECK_BAD_KIND=""
    PE_CHECK_OS_MAJOR=""
    PE_CHECK_OS_MINOR=""
    PE_CHECK_SUBSYS_MAJOR=""
    PE_CHECK_SUBSYS_MINOR=""

    # Try to read the PE header with objdump.
    local dump
    if ! dump=$(objdump -p "$exe" 2>/dev/null); then
        PE_CHECK_RESULT="skip"
        return 2
    fi

    local fail=0
    local reasons=()

    # ── DLL-name substring check (cheap; runs first) ─────────────────────────
    while IFS= read -r dll_name; do
        local dll_lc="${dll_name,,}"
        for pat in "${PE_FORBIDDEN_IMPORT_PATTERNS[@]}"; do
            if [[ "$dll_lc" == *"$pat"* ]]; then
                PE_CHECK_BAD_IMPORT="$dll_name"
                reasons+=("forbidden import: $dll_name")
                fail=1
                break 2
            fi
        done
    done < <(printf '%s\n' "$dump" | awk '/DLL Name:/ {print $3}')

    # ── Per-import allowlist + denylist check ────────────────────────────────
    #    Allowlist: DLL must be in snapshot, every named function must be in
    #    that DLL's export list.
    #    Denylist: if the function IS exported by Win98 SE but is on the
    #    behavioral denylist (stub-only — binds but always fails at runtime),
    #    reject it with a distinct reason.
    if [[ "$fail" -eq 0 && -n "${PE_CHECK_ALLOWLIST:-}" \
          && -f "$PE_CHECK_ALLOWLIST" ]] && command -v jq >/dev/null 2>&1; then
        _pe_check_allowlist "$dump" || fail=1
        if [[ -n "$PE_CHECK_BAD_FUNCTION" ]]; then
            case "$PE_CHECK_BAD_KIND" in
                denied)
                    reasons+=("Win98 stub-only (binds but non-functional): $PE_CHECK_BAD_FUNCTION")
                    ;;
                *)
                    reasons+=("import not available on Win98: $PE_CHECK_BAD_FUNCTION")
                    ;;
            esac
        elif [[ -n "$PE_CHECK_BAD_IMPORT" && "$fail" -eq 1 ]]; then
            reasons+=("DLL not present on Win98: $PE_CHECK_BAD_IMPORT")
        fi
    fi

    # ── PE OS / Subsystem version checks ─────────────────────────────────────
    # No `exit` in the awk: each of these fields appears exactly once in
    # `objdump -p`, and `exit` would close the pipe early — when the caller
    # has set -o pipefail (the verify-*.sh scripts do), the printf gets
    # SIGPIPE and the assignment fails with 141, killing the whole verify
    # run. Letting awk read to EOF costs nothing on this small input.
    PE_CHECK_OS_MAJOR=$(printf '%s\n' "$dump" | awk '/MajorOSystemVersion/ {print $2}')
    PE_CHECK_OS_MINOR=$(printf '%s\n' "$dump" | awk '/MinorOSystemVersion/ {print $2}')
    PE_CHECK_SUBSYS_MAJOR=$(printf '%s\n' "$dump" | awk '/MajorSubsystemVersion/ {print $2}')
    PE_CHECK_SUBSYS_MINOR=$(printf '%s\n' "$dump" | awk '/MinorSubsystemVersion/ {print $2}')

    if [[ -n "$PE_CHECK_OS_MAJOR" && "$PE_CHECK_OS_MAJOR" -gt 4 ]]; then
        reasons+=("MajorOSVersion=$PE_CHECK_OS_MAJOR (must be ≤ 4 for Win98)")
        fail=1
    fi
    if [[ -n "$PE_CHECK_SUBSYS_MAJOR" && "$PE_CHECK_SUBSYS_MAJOR" -gt 4 ]]; then
        reasons+=("MajorSubsystemVersion=$PE_CHECK_SUBSYS_MAJOR (must be ≤ 4 for Win98)")
        fail=1
    fi

    if [[ "$fail" -eq 0 ]]; then
        PE_CHECK_RESULT="pass"
        return 0
    fi

    # Join reasons with "; ".
    local joined=""
    local r
    for r in "${reasons[@]}"; do
        [[ -n "$joined" ]] && joined+="; "
        joined+="$r"
    done
    PE_CHECK_FAIL_REASON="$joined"
    PE_CHECK_RESULT="fail"
    return 1
}

# _pe_check_allowlist <objdump-output>
# Walks each imported DLL block in the dump and, against the JSON allowlist
# AND the optional behavioral denylist, verifies the DLL is known, every
# named import is in its export list, and no named import is on the
# behavioral denylist for its DLL.
# Sets PE_CHECK_BAD_IMPORT (DLL), PE_CHECK_BAD_FUNCTION (DLL:func), and
# PE_CHECK_BAD_KIND ("missing"|"denied") on first failure.
# Returns 0 on full pass, 1 on first failure.
_pe_check_allowlist() {
    local dump="$1"
    local allowlist_dlls
    if ! allowlist_dlls=$(jq -r '.dlls | keys[]' "$PE_CHECK_ALLOWLIST" 2>/dev/null); then
        # Bad JSON — treat as "allowlist not usable" rather than failing the binary.
        return 0
    fi
    # Build a bash-set of known DLL names (lower-case).
    declare -A _known_dll=()
    local d
    while IFS= read -r d; do
        _known_dll["$d"]=1
    done <<< "$allowlist_dlls"

    # Bundled-DLL set: imports from these names are passed through without
    # any export-table check (they're shims we ship in the package).
    declare -A _bundled_dll=()
    local b
    for b in ${PE_CHECK_BUNDLED_DLLS:-}; do
        _bundled_dll["${b,,}"]=1
    done

    # Denylist availability — if the file is present and parses, we'll lazy-
    # load the per-DLL denied set alongside the export set. Missing or broken
    # denylist file = degraded mode (only the export-table check runs).
    local denylist_active=0
    if [[ -n "${PE_CHECK_DENYLIST:-}" && -f "${PE_CHECK_DENYLIST}" ]] \
       && jq -e '.denied_exports' "$PE_CHECK_DENYLIST" >/dev/null 2>&1; then
        denylist_active=1
    fi

    # Walk the import section once, tracking current DLL and validating each
    # named import row against the cached export list for that DLL.
    local current_dll="" current_dll_lc=""
    local current_exports_loaded=0
    local current_denied_loaded=0
    local current_bundled=0
    declare -A _exports=()  # symbol -> 1 for the current DLL (allowlist)
    declare -A _denied=()   # symbol -> 1 for the current DLL (behavioral denylist)

    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+DLL\ Name:[[:space:]]+(.+)$ ]]; then
            current_dll="${BASH_REMATCH[1]}"
            current_dll="${current_dll%$'\r'}"
            current_dll_lc="${current_dll,,}"
            current_exports_loaded=0
            current_denied_loaded=0
            current_bundled=0
            _exports=()
            _denied=()

            # Bundled DLLs bypass system-allowlist and function checks.
            if [[ -n "${_bundled_dll[$current_dll_lc]:-}" ]]; then
                current_bundled=1
                continue
            fi
            if [[ -z "${_known_dll[$current_dll_lc]:-}" ]]; then
                PE_CHECK_BAD_IMPORT="$current_dll"
                PE_CHECK_BAD_KIND="missing"
                return 1
            fi
            continue
        fi

        # Skip import rows for a bundled DLL.
        if [[ "$current_bundled" -eq 1 ]]; then
            continue
        fi

        # Named-import row. binutils' objdump emits this in two different
        # layouts depending on version (see AGENTS.md §5.9):
        #
        #   3-col (older, e.g. Ubuntu 22.04 / binutils 2.38, our toolchain-
        #          builder container):
        #     "vma:  Hint/Ord  Member-Name  Bound-To"
        #     "\t446ba\t 1257  _stati64"
        #
        #   4-col (newer, e.g. mingw-w64 binutils on the host):
        #     "vma:  Ordinal  Hint  Member-Name  Bound-To"
        #     "\t446ba  <none>  04e9  _stati64"
        #
        # Bound-To is empty on every row in both layouts (we don't pre-bind).
        # We try the 4-col layout first because it's strictly more specific:
        # the 3-col regex would silently mis-match a 4-col row (capturing the
        # Hint column instead of the symbol). Either of the two regexes
        # matching is fine — we extract the symbol from whichever fires.
        # This auto-detect lets us survive an Ubuntu base-image bump without
        # silently flipping the per-function check into a no-op.
        local sym=""
        if [[ "$line" =~ ^[[:space:]]+[0-9a-fA-F]+[[:space:]]+(\<none\>|[0-9]+)[[:space:]]+[0-9a-fA-F]+[[:space:]]+([A-Za-z_][A-Za-z0-9_@?$]*) ]]; then
            sym="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]+[0-9a-fA-F]+[[:space:]]+(\<none\>|[0-9]+)[[:space:]]+([A-Za-z_][A-Za-z0-9_@?$]*) ]]; then
            sym="${BASH_REMATCH[2]}"
        fi
        if [[ -n "$sym" ]]; then
            if [[ -z "$current_dll" ]]; then
                continue
            fi
            if [[ "$current_exports_loaded" -eq 0 ]]; then
                # Lazy-load the export set for this DLL on first import row.
                while IFS= read -r e; do
                    _exports["$e"]=1
                done < <(jq -r --arg d "$current_dll_lc" '.dlls[$d][]' "$PE_CHECK_ALLOWLIST")
                current_exports_loaded=1
            fi
            if [[ -z "${_exports[$sym]:-}" ]]; then
                PE_CHECK_BAD_IMPORT="$current_dll"
                PE_CHECK_BAD_FUNCTION="$current_dll:$sym"
                PE_CHECK_BAD_KIND="missing"
                return 1
            fi
            # Symbol is in the export table. Now check the behavioral denylist.
            # An entry there means "exported by Win98 SE but always fails at
            # runtime (stub)" — reject those even though they bind cleanly.
            if [[ "$denylist_active" -eq 1 ]]; then
                if [[ "$current_denied_loaded" -eq 0 ]]; then
                    # Lazy-load the denied set for this DLL on first import row.
                    # `.denied_exports[$d] // []` returns an empty array when
                    # the DLL has no denylist entries (common case), which the
                    # `[]` projection then yields zero rows for — no-op load.
                    while IFS= read -r e; do
                        [[ -n "$e" ]] && _denied["$e"]=1
                    done < <(jq -r --arg d "$current_dll_lc" '.denied_exports[$d] // [] | .[]' "$PE_CHECK_DENYLIST")
                    current_denied_loaded=1
                fi
                if [[ -n "${_denied[$sym]:-}" ]]; then
                    PE_CHECK_BAD_IMPORT="$current_dll"
                    PE_CHECK_BAD_FUNCTION="$current_dll:$sym"
                    PE_CHECK_BAD_KIND="denied"
                    return 1
                fi
            fi
        fi
    done <<< "$dump"

    return 0
}

# ── Direct CLI usage ─────────────────────────────────────────────────────────
# Only run main logic when this script is executed directly, not sourced.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -eq 0 ]]; then
        echo "Usage: $(basename "$0") <exe> [<exe2> ...]" >&2
        exit 1
    fi

    overall=0
    for exe in "$@"; do
        pe_check_win98 "$exe"
        rc=$?
        case "$rc" in
            0)
                ver=""
                [[ -n "$PE_CHECK_OS_MAJOR" ]] && ver+="  OS=$PE_CHECK_OS_MAJOR.${PE_CHECK_OS_MINOR:-0}"
                [[ -n "$PE_CHECK_SUBSYS_MAJOR" ]] && ver+="  Subsys=$PE_CHECK_SUBSYS_MAJOR.${PE_CHECK_SUBSYS_MINOR:-0}"
                echo "[PASS] $exe$ver"
                ;;
            1)
                echo "[FAIL] $exe — $PE_CHECK_FAIL_REASON"
                overall=1
                ;;
            2)
                echo "[SKIP] $exe (not a PE or objdump failed)"
                ;;
        esac
    done
    exit "$overall"
fi
