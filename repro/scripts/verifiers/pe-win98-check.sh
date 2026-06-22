#!/usr/bin/env bash
# ============================================================================
# pe-win98-check.sh — Shared Win98 PE compatibility checker
# ============================================================================
# Can be SOURCED by other scripts or CALLED directly as a CLI tool.
#
# When sourced, provides:
#   pe_check_win98 <exe>
#     Inspects the PE binary at <exe> using objdump. Runs every check phase
#     (DLL substring, allowlist, behavioral denylist, OS version) to completion
#     so a single call surfaces every Win98 incompatibility in the binary —
#     not just the first one. PE_CHECK_FAIL_REASON is the "; "-joined list.
#     Returns:
#       0  — Win98 compatible
#       1  — incompatible (sets PE_CHECK_FAIL_REASON)
#       2  — not a PE / objdump failed (skip)
#     Sets these variables on every call:
#       PE_CHECK_RESULT       "pass" | "fail" | "skip"
#       PE_CHECK_FAIL_REASON  human-readable failure description, "; "-joined
#                             across all findings (non-empty on fail)
#       PE_CHECK_BAD_IMPORT   FIRST offending DLL name (non-empty if any
#                             DLL-level failure was recorded)
#       PE_CHECK_BAD_FUNCTION FIRST offending DLL:function (non-empty if any
#                             import-level failure was recorded)
#       PE_CHECK_BAD_KIND     "missing" if the function isn't in the allowlist,
#                             "denied"  if it's in the allowlist but on the
#                                       behavioral denylist (stub-only on Win98);
#                             reflects the FIRST failure recorded
#       PE_CHECK_OS_MAJOR     MajorOSVersion integer (empty if not found)
#       PE_CHECK_OS_MINOR     MinorOSVersion integer (empty if not found)
#       PE_CHECK_SUBSYS_MAJOR MajorSubsystemVersion integer (empty if not found)
#       PE_CHECK_SUBSYS_MINOR MinorSubsystemVersion integer (empty if not found)
#     Note: the three PE_CHECK_BAD_* scalars are first-failure for back-compat
#     with the documented API; FAIL_REASON is the authoritative full list.
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
#
# When invoked via the cross-toolchain $PREFIX/bin/pe-win98-check wrapper
# symlink, BASH_SOURCE[0] is the symlink path itself — a naive
# `cd $(dirname $BASH_SOURCE) && pwd` leaves us in bin/, both candidate
# paths miss, and the per-function check silently skips. Walk symlinks
# until we land on the real script before computing self_dir.
_pe_check_resolve_data() {
    local basename="$1"
    local src="${BASH_SOURCE[0]}"
    while [[ -L "$src" ]]; do
        local link_dir
        link_dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$link_dir/$src"
    done
    local self_dir
    self_dir="$(cd -P "$(dirname "$src")" && pwd)"
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

# One-shot warning when the per-function/denylist check can't run. The cheaper
# DLL-substring + OS-version checks still cover the most common forbidden
# imports (ucrt, vcruntime, api-ms-win-*), so the binary may still get a
# correct [FAIL]. But silently skipping the per-function check led to a real
# false-PASS on the consumer image (gdb.exe imports bcrypt.dll → DLL not on
# Win98, but checker returned rc=0). Loud is better than silent.
_pe_check_warn_degraded_once() {
    if [[ -n "${_PE_CHECK_WARNED_DEGRADED:-}" ]]; then
        return
    fi
    _PE_CHECK_WARNED_DEGRADED=1
    local reason="$1"
    printf '[WARN] pe-win98-check: %s\n' "$reason" >&2
    printf '[WARN] pe-win98-check: per-function and behavioral-denylist checks SKIPPED — a binary that imports an unknown DLL or a stub-only export may falsely report PASS.\n' >&2
}

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
    # `reasons` and `_substring_flagged` are local but reachable via dynamic
    # scoping from _pe_check_allowlist — that helper appends each finding it
    # discovers, mirroring how this top-level loop does its own DLL-substring
    # appends. Tracking substring-hit DLLs here lets the inner function skip
    # the import rows of an already-flagged DLL (otherwise a ucrt or
    # vcruntime hit would explode into one "DLL not present" plus one
    # "import not available" line per imported symbol).
    local reasons=()
    declare -A _substring_flagged=()

    # ── DLL-name substring check (cheap; runs first) ─────────────────────────
    # All-results mode: don't bail on first match; collect every forbidden
    # DLL the binary imports. Most binaries hit zero or one of these, but
    # the loop must keep scanning so the caller sees the full set.
    while IFS= read -r dll_name; do
        local dll_lc="${dll_name,,}"
        for pat in "${PE_FORBIDDEN_IMPORT_PATTERNS[@]}"; do
            if [[ "$dll_lc" == *"$pat"* ]]; then
                : "${PE_CHECK_BAD_IMPORT:=$dll_name}"
                reasons+=("forbidden import: $dll_name")
                _substring_flagged["$dll_lc"]=1
                fail=1
                break
            fi
        done
    done < <(printf '%s\n' "$dump" | awk '/DLL Name:/ {print $3}')

    # ── Per-import allowlist + denylist check ────────────────────────────────
    #    Allowlist: DLL must be in snapshot, every named function must be in
    #    that DLL's export list.
    #    Denylist: if the function IS exported by Win98 SE but is on the
    #    behavioral denylist (stub-only — binds but always fails at runtime),
    #    reject it with a distinct reason.
    #
    #    Always runs when configured (no early-exit on substring failures),
    #    so a binary that imports both ucrt and a bunch of Vista+ kernel32
    #    symbols reports both classes of problem in one pass.
    #
    #    PE_CHECK_ALLOWLIST="" (explicit empty) means "skip the per-function
    #    check, don't warn" — caller has opted out. Anything else (default or
    #    explicit path) but a missing file or missing jq is a *degraded* run
    #    and gets a one-shot stderr warning so the user knows the checker
    #    didn't run at full strength.
    if [[ -n "${PE_CHECK_ALLOWLIST:-}" ]]; then
        if [[ ! -f "$PE_CHECK_ALLOWLIST" ]]; then
            _pe_check_warn_degraded_once "allowlist not found at $PE_CHECK_ALLOWLIST"
        elif ! command -v jq >/dev/null 2>&1; then
            _pe_check_warn_degraded_once "jq not available on PATH (required for per-function and behavioral-denylist checks)"
        else
            # _pe_check_allowlist now appends each finding to `reasons`
            # itself; no caller-side reason assembly needed.
            _pe_check_allowlist "$dump" || fail=1
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
#
# All-failures mode: this function does NOT bail on the first issue. Each
# missing DLL, missing function, and denied function is appended to the
# `reasons` array owned by the caller (pe_check_win98) via dynamic scoping.
# The scalar PE_CHECK_BAD_IMPORT / PE_CHECK_BAD_FUNCTION / PE_CHECK_BAD_KIND
# globals stay populated with the FIRST failure for back-compat with the
# documented API — no caller currently reads them, but the contract is
# documented at the top of this file.
#
# Substring-flagged DLLs (`_substring_flagged[$dll_lc]` set by the caller)
# are treated as bundled: we don't emit a "DLL not present" reason for
# them (the substring check already did) and we don't probe their imports.
# Without this suppression, a single ucrt/vcruntime import would explode
# into one "forbidden" + one "DLL not present" + one "import not available"
# per function it brought in.
#
# Returns 0 on full pass, 1 if any failure was recorded.
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
    local current_bundled=0  # also reused as "skip rows" for already-flagged DLLs
    declare -A _exports=()  # symbol -> 1 for the current DLL (allowlist)
    declare -A _denied=()   # symbol -> 1 for the current DLL (behavioral denylist)
    local found_failure=0

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

            # Bundled DLLs (shims we ship) bypass system-allowlist and
            # function checks entirely.
            if [[ -n "${_bundled_dll[$current_dll_lc]:-}" ]]; then
                current_bundled=1
                continue
            fi
            # Already flagged by the caller's DLL-substring check (ucrt /
            # vcruntime / api-ms-win-*). Don't add a duplicate "DLL not
            # present" reason and don't probe its imports.
            if [[ -n "${_substring_flagged[$current_dll_lc]:-}" ]]; then
                current_bundled=1
                continue
            fi
            if [[ -z "${_known_dll[$current_dll_lc]:-}" ]]; then
                : "${PE_CHECK_BAD_IMPORT:=$current_dll}"
                : "${PE_CHECK_BAD_KIND:=missing}"
                reasons+=("DLL not present on Win98: $current_dll")
                found_failure=1
                # Skip this DLL's import rows — every function it exports is
                # by definition not in our allowlist (we don't have an
                # export table for an unknown DLL), so probing them would
                # generate N redundant "import not available" lines.
                current_bundled=1
                continue
            fi
            continue
        fi

        # Skip import rows for a bundled / already-flagged DLL.
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
                : "${PE_CHECK_BAD_IMPORT:=$current_dll}"
                : "${PE_CHECK_BAD_FUNCTION:=$current_dll:$sym}"
                : "${PE_CHECK_BAD_KIND:=missing}"
                reasons+=("import not available on Win98: $current_dll:$sym")
                found_failure=1
                continue
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
                    : "${PE_CHECK_BAD_IMPORT:=$current_dll}"
                    : "${PE_CHECK_BAD_FUNCTION:=$current_dll:$sym}"
                    : "${PE_CHECK_BAD_KIND:=denied}"
                    reasons+=("Win98 stub-only (binds but non-functional): $current_dll:$sym")
                    found_failure=1
                fi
            fi
        fi
    done <<< "$dump"

    return $found_failure
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
