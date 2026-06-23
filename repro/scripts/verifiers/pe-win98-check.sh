#!/bin/sh
# ============================================================================
# pe-win98-check.sh — Shared Win98 PE compatibility checker (POSIX sh)
# ============================================================================
# Can be SOURCED by other scripts or CALLED directly as a CLI tool.
# Runs unmodified under bash, dash, and busybox-w32 ash — so the same script
# ships in (a) the build environment, (b) the cross-toolchain tarball, and
# (c) the extras toolset on Win98.
#
# Public interface (sourced use):
#
#   pe_check_win98 <exe>
#     Inspects the PE binary at <exe> using objdump. Runs every check phase
#     (DLL substring, allowlist, behavioral denylist, OS version) to completion
#     so a single call surfaces every Win98 incompatibility — not just the
#     first one. PE_CHECK_FAIL_REASON is the "; "-joined list.
#     Returns:
#       0  — Win98 compatible
#       1  — incompatible (sets PE_CHECK_FAIL_REASON)
#       2  — not a PE / objdump failed (skip)
#     Sets these variables on every call:
#       PE_CHECK_RESULT       "pass" | "fail" | "skip"
#       PE_CHECK_FAIL_REASON  human-readable failure description, "; "-joined
#       PE_CHECK_BAD_IMPORT   FIRST offending DLL name
#       PE_CHECK_BAD_FUNCTION FIRST offending DLL:function
#       PE_CHECK_BAD_KIND     "missing" | "denied" (FIRST recorded)
#       PE_CHECK_OS_MAJOR     MajorOSystemVersion integer (empty if not found)
#       PE_CHECK_OS_MINOR     MinorOSystemVersion integer
#       PE_CHECK_SUBSYS_MAJOR MajorSubsystemVersion integer
#       PE_CHECK_SUBSYS_MINOR MinorSubsystemVersion integer
#
# Environment variables:
#   PE_CHECK_ALLOWLIST    path to win98se-api-allowlist.json
#                         (default: auto-resolved relative to this script)
#                         "" = skip per-function check entirely
#   PE_CHECK_DENYLIST     path to win98-behavioral-denylist.json
#                         (default: auto-resolved)
#                         "" = skip denylist check entirely
#   PE_CHECK_BUNDLED_DLLS space-separated list of DLL basenames whose imports
#                         should be passed through (shims shipped alongside)
#   OBJDUMP               objdump binary to use (default: probe PATH for
#                         `objdump` then `i686-w64-mingw32-objdump`)
#
# Direct CLI usage:
#   pe-win98-check.sh <exe> [<exe2> ...]
#   Exit 0 if all pass; 1 if any fail.
#
# Design notes (for the maintainer):
#   * All matching logic runs inside a single awk pass over the dump. The
#     allowlist + denylist are pre-flattened by jq to a "tag!arg[!arg]" stream
#     that awk's BEGIN block loads into associative arrays. Two jq calls
#     total, vs. one-jq-per-imported-DLL in the prior bash implementation —
#     meaningful win on Win98 where each fork/exec is ~50-100ms.
#   * Self-locator: $BASH_SOURCE (bash) / $0 (everything else). No symlink
#     walking — FAT32 has no symlinks; for the cross-tarball Linux symlink
#     wrapper (bin/pe-win98-check → ../share/win98-verify/...), the resolver
#     explicitly probes ../share/win98-verify/ relative to self_dir.
#   * objdump-import-row parsing: $NF strategy (last whitespace-separated
#     field is the symbol). Works for both the 3-col and 4-col objdump
#     layouts AGENTS.md §5.9 documents, without needing a layout sniff.
# ============================================================================

# Don't use `set -u` / `set -e` here — this file may be sourced from scripts
# with their own shell-option preferences. Be careful with ${var:-} on every
# maybe-unset access.

# ----------------------------------------------------------------------------
# Self-location and data-file defaults.
# ----------------------------------------------------------------------------
# $BASH_SOURCE is set in bash (when sourced or executed); in ash/dash it's
# unset and we fall back to $0. For sourced use in non-bash shells the caller
# must set PE_CHECK_ALLOWLIST / PE_CHECK_DENYLIST explicitly — the auto-locate
# can only work for CLI invocation there.
_pe_check_self="${BASH_SOURCE:-$0}"

_pe_check_resolve_data() {
    _basename=$1
    _self_dir=$(cd -P "$(dirname "$_pe_check_self")" 2>/dev/null && pwd)
    if [ -z "$_self_dir" ]; then
        # Couldn't locate self — return repo-relative path; caller's existence
        # check will fall through to the degraded-mode warning.
        printf '%s\n' "../../data/$_basename"
        return
    fi
    # Repo layout: scripts/verifiers/<this> + ../data/<file>
    if [ -f "$_self_dir/../../data/$_basename" ]; then
        printf '%s\n' "$_self_dir/../../data/$_basename"
        return
    fi
    # Flat installed layout: share/win98-verify/<this> + share/win98-verify/<file>
    if [ -f "$_self_dir/$_basename" ]; then
        printf '%s\n' "$_self_dir/$_basename"
        return
    fi
    # Cross-tarball bin/ wrapper layout: bin/pe-win98-check symlinks onto
    # ../share/win98-verify/pe-win98-check.sh, but `dirname $0` gives bin/
    # (we have no readlink in busybox). Probe ../share/win98-verify/ for
    # the data file so the wrapper invocation works without symlink walking.
    if [ -f "$_self_dir/../share/win98-verify/$_basename" ]; then
        printf '%s\n' "$_self_dir/../share/win98-verify/$_basename"
        return
    fi
    printf '%s\n' "$_self_dir/../../data/$_basename"
}

: "${PE_CHECK_ALLOWLIST=$(_pe_check_resolve_data win98se-api-allowlist.json)}"
: "${PE_CHECK_DENYLIST=$(_pe_check_resolve_data win98-behavioral-denylist.json)}"

# Back-compat aliases — the install scripts call these to verify the bundled
# checker resolves its data files post-install. Kept here as named entry
# points so the install-pe-checker* verification hooks don't have to grow
# new code when the resolver changes shape.
_pe_check_default_allowlist() { _pe_check_resolve_data "win98se-api-allowlist.json"; }
_pe_check_default_denylist()  { _pe_check_resolve_data "win98-behavioral-denylist.json"; }

# ----------------------------------------------------------------------------
# Degraded-mode one-shot warning. Mirrors the bash version's behavior so
# downstream users see the same "we ran with reduced coverage" signal.
# ----------------------------------------------------------------------------
_PE_CHECK_WARNED_DEGRADED=
_pe_check_warn_degraded_once() {
    if [ -n "$_PE_CHECK_WARNED_DEGRADED" ]; then return; fi
    _PE_CHECK_WARNED_DEGRADED=1
    printf '[WARN] pe-win98-check: %s\n' "$1" >&2
    printf '[WARN] pe-win98-check: per-function and behavioral-denylist checks SKIPPED — a binary that imports an unknown DLL or a stub-only export may falsely report PASS.\n' >&2
}

# ----------------------------------------------------------------------------
# objdump probe. Cross-toolchain bin/ on Linux only ships
# i686-w64-mingw32-objdump; native toolset on Win98 ships both. Honor the
# OBJDUMP env override first (also fixes the latent hardcoded `objdump` bug
# in the old script).
# ----------------------------------------------------------------------------
_pe_check_find_objdump() {
    if [ -n "${OBJDUMP:-}" ] && command -v "$OBJDUMP" >/dev/null 2>&1; then
        printf '%s\n' "$OBJDUMP"
        return 0
    fi
    if command -v objdump >/dev/null 2>&1; then
        printf '%s\n' "objdump"
        return 0
    fi
    if command -v i686-w64-mingw32-objdump >/dev/null 2>&1; then
        printf '%s\n' "i686-w64-mingw32-objdump"
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# pe_check_win98 <exe>
# ----------------------------------------------------------------------------
pe_check_win98() {
    _exe=$1

    # Reset all output globals.
    PE_CHECK_RESULT=""
    PE_CHECK_FAIL_REASON=""
    PE_CHECK_BAD_IMPORT=""
    PE_CHECK_BAD_FUNCTION=""
    PE_CHECK_BAD_KIND=""
    PE_CHECK_OS_MAJOR=""
    PE_CHECK_OS_MINOR=""
    PE_CHECK_SUBSYS_MAJOR=""
    PE_CHECK_SUBSYS_MINOR=""

    _objdump=$(_pe_check_find_objdump) || {
        PE_CHECK_RESULT="skip"
        return 2
    }

    # Per-call tempdir (no trap — sourced callers may have their own).
    _tmpdir=$(mktemp -d 2>/dev/null) || _tmpdir="${TMPDIR:-/tmp}/pe-check.$$"
    mkdir -p "$_tmpdir" 2>/dev/null || {
        PE_CHECK_RESULT="skip"
        return 2
    }

    # Dump the PE header. Failure here means not a PE / objdump rejected.
    if ! "$_objdump" -p "$_exe" >"$_tmpdir/dump" 2>/dev/null; then
        rm -rf "$_tmpdir"
        PE_CHECK_RESULT="skip"
        return 2
    fi

    # Pre-flatten allowlist + denylist via jq into a stream awk can load
    # in BEGIN. Two layered fallbacks for degraded modes:
    #   PE_CHECK_ALLOWLIST=""  -> caller opted out, no warning
    #   PE_CHECK_ALLOWLIST=<missing file or no jq>  -> warn once
    : >"$_tmpdir/allow"
    : >"$_tmpdir/deny"
    _allow_active=0
    _deny_active=0
    if [ -n "${PE_CHECK_ALLOWLIST:-}" ]; then
        if [ ! -f "$PE_CHECK_ALLOWLIST" ]; then
            _pe_check_warn_degraded_once "allowlist not found at $PE_CHECK_ALLOWLIST"
        elif ! command -v jq >/dev/null 2>&1; then
            _pe_check_warn_degraded_once "jq not available on PATH (required for per-function and behavioral-denylist checks)"
        else
            if jq -r '
                .dlls // {} | to_entries[] |
                (("dll!" + .key), (.key as $d | .value[] | "sym!" + $d + "!" + .))
            ' "$PE_CHECK_ALLOWLIST" >"$_tmpdir/allow" 2>/dev/null; then
                _allow_active=1
            fi
            if [ -n "${PE_CHECK_DENYLIST:-}" ] && [ -f "$PE_CHECK_DENYLIST" ]; then
                if jq -r '
                    .denied_exports // {} | to_entries[] |
                    (.key as $d | .value[] | "deny!" + $d + "!" + .)
                ' "$PE_CHECK_DENYLIST" >"$_tmpdir/deny" 2>/dev/null; then
                    _deny_active=1
                fi
            fi
        fi
    fi

    # Run the single-pass awk. Outputs lines prefixed with a tag the shell
    # parses below. Tags:
    #   BAD_IMPORT:<dll>           — first failing DLL (back-compat scalar)
    #   BAD_FUNCTION:<dll>:<sym>   — first failing function (back-compat scalar)
    #   BAD_KIND:missing|denied    — kind of the first failure
    #   OS_MAJOR:<n>, OS_MINOR:<n>, SUBSYS_MAJOR:<n>, SUBSYS_MINOR:<n>
    #   REASON:<text>              — one line per finding (joined with "; ")
    #   RESULT:pass|fail           — single trailing verdict
    awk \
        -v ALLOW_FILE="$_tmpdir/allow" \
        -v DENY_FILE="$_tmpdir/deny" \
        -v ALLOW_ACTIVE="$_allow_active" \
        -v DENY_ACTIVE="$_deny_active" \
        -v BUNDLED_DLLS="${PE_CHECK_BUNDLED_DLLS:-}" \
    '
    BEGIN {
        # Forbidden-substring patterns (lower-case; mirrors PE_FORBIDDEN_IMPORT_PATTERNS).
        n_forbidden = 3
        forbidden[1] = "api-ms-win-"
        forbidden[2] = "ucrtbase.dll"
        forbidden[3] = "vcruntime"

        # Load flattened allowlist into known_dll[] and export_set["<dll_lc>!<sym>"].
        if (ALLOW_ACTIVE == "1") {
            while ((getline line < ALLOW_FILE) > 0) {
                n = split(line, p, "!")
                if (n == 2 && p[1] == "dll") {
                    known_dll[tolower(p[2])] = 1
                } else if (n == 3 && p[1] == "sym") {
                    export_set[tolower(p[2]) "!" p[3]] = 1
                }
            }
            close(ALLOW_FILE)
        }

        # Load flattened denylist into denied_set["<dll_lc>!<sym>"].
        if (DENY_ACTIVE == "1") {
            while ((getline line < DENY_FILE) > 0) {
                n = split(line, p, "!")
                if (n == 3 && p[1] == "deny") {
                    denied_set[tolower(p[2]) "!" p[3]] = 1
                }
            }
            close(DENY_FILE)
        }

        # Bundled DLLs (space-separated, case-insensitive).
        n_bundled = split(BUNDLED_DLLS, b_arr, " ")
        for (i = 1; i <= n_bundled; i++) {
            if (b_arr[i] != "") bundled[tolower(b_arr[i])] = 1
        }

        current_dll = ""
        current_dll_lc = ""
        skip_rows = 0
        fail = 0
    }

    # DLL Name header: "\tDLL Name: KERNEL32.dll"
    /DLL Name:/ {
        current_dll = $3
        sub(/\r$/, "", current_dll)
        current_dll_lc = tolower(current_dll)
        skip_rows = 0

        # 1. Forbidden substring check (ucrt, vcruntime, api-ms-win-*).
        for (i = 1; i <= n_forbidden; i++) {
            if (index(current_dll_lc, forbidden[i]) > 0) {
                if (BAD_IMPORT == "") {
                    BAD_IMPORT = current_dll
                    print "BAD_IMPORT:" current_dll
                }
                print "REASON:forbidden import: " current_dll
                substring_flagged[current_dll_lc] = 1
                skip_rows = 1
                fail = 1
                break
            }
        }
        if (skip_rows) next

        # 2. Bundled DLL — pass through entirely (shim shipped alongside).
        if (current_dll_lc in bundled) {
            skip_rows = 1
            next
        }

        # 3. Allowlist check (only when active).
        if (ALLOW_ACTIVE == "1") {
            if (!(current_dll_lc in known_dll)) {
                if (BAD_IMPORT == "") {
                    BAD_IMPORT = current_dll
                    print "BAD_IMPORT:" current_dll
                }
                if (BAD_KIND == "") {
                    BAD_KIND = "missing"
                    print "BAD_KIND:missing"
                }
                print "REASON:DLL not present on Win98: " current_dll
                skip_rows = 1
                fail = 1
                next
            }
        }
        next
    }

    # Named-import row. Both objdump layouts (3-col and 4-col, see AGENTS.md
    # §5.9) have the symbol as the last whitespace-separated field. We anchor
    # on "leading whitespace + hex" to skip the "vma:" column-header row and
    # section dividers.
    /^[ \t]+[0-9a-fA-F]+[ \t]/ {
        if (skip_rows) next
        if (current_dll == "") next
        # Per-function check only when allowlist is active.
        if (ALLOW_ACTIVE != "1") next

        sym = $NF
        # Filter rows where $NF is not a valid symbol — e.g. ordinal-only
        # imports that have no Member-Name column.
        if (sym !~ /^[A-Za-z_]/) next

        key = current_dll_lc "!" sym

        if (!(key in export_set)) {
            if (BAD_IMPORT == "") {
                BAD_IMPORT = current_dll
                print "BAD_IMPORT:" current_dll
            }
            if (BAD_FUNCTION == "") {
                BAD_FUNCTION = current_dll ":" sym
                print "BAD_FUNCTION:" current_dll ":" sym
            }
            if (BAD_KIND == "") {
                BAD_KIND = "missing"
                print "BAD_KIND:missing"
            }
            print "REASON:import not available on Win98: " current_dll ":" sym
            fail = 1
            next
        }

        # Symbol is in the allowlist — now check the behavioral denylist.
        if (DENY_ACTIVE == "1" && (key in denied_set)) {
            if (BAD_IMPORT == "") {
                BAD_IMPORT = current_dll
                print "BAD_IMPORT:" current_dll
            }
            if (BAD_FUNCTION == "") {
                BAD_FUNCTION = current_dll ":" sym
                print "BAD_FUNCTION:" current_dll ":" sym
            }
            if (BAD_KIND == "") {
                BAD_KIND = "denied"
                print "BAD_KIND:denied"
            }
            print "REASON:Win98 stub-only (binds but non-functional): " current_dll ":" sym
            fail = 1
        }
    }

    # OS / Subsystem version fields appear exactly once each in objdump -p.
    # Captures stay informational; the integer threshold check is here too.
    /MajorOSystemVersion/ {
        os_major = $2
        print "OS_MAJOR:" os_major
        if (os_major + 0 > 4) {
            print "REASON:MajorOSVersion=" os_major " (must be <= 4 for Win98)"
            fail = 1
        }
    }
    /MinorOSystemVersion/    { print "OS_MINOR:" $2 }
    /MajorSubsystemVersion/ {
        subsys_major = $2
        print "SUBSYS_MAJOR:" subsys_major
        if (subsys_major + 0 > 4) {
            print "REASON:MajorSubsystemVersion=" subsys_major " (must be <= 4 for Win98)"
            fail = 1
        }
    }
    /MinorSubsystemVersion/  { print "SUBSYS_MINOR:" $2 }

    END {
        if (fail) print "RESULT:fail"; else print "RESULT:pass"
    }
    ' "$_tmpdir/dump" >"$_tmpdir/awk-out" 2>/dev/null

    # Parse the awk output. All extraction uses prefix match + ${var#prefix}
    # rather than IFS=: read, because BAD_FUNCTION and REASON values both
    # contain ":" themselves (`dll:sym` and `import not available on Win98:
    # dll:sym` respectively) and IFS=: would truncate them. REASON
    # accumulates (joined with "; "); BAD_* scalars stay first-finding-only
    # (the awk above enforces that on its side too — these checks are
    # defensive).
    _result=pass
    while IFS= read -r _line; do
        case "$_line" in
            BAD_IMPORT:*)
                [ -z "$PE_CHECK_BAD_IMPORT" ] && PE_CHECK_BAD_IMPORT=${_line#BAD_IMPORT:}
                ;;
            BAD_FUNCTION:*)
                [ -z "$PE_CHECK_BAD_FUNCTION" ] && PE_CHECK_BAD_FUNCTION=${_line#BAD_FUNCTION:}
                ;;
            BAD_KIND:*)
                [ -z "$PE_CHECK_BAD_KIND" ] && PE_CHECK_BAD_KIND=${_line#BAD_KIND:}
                ;;
            OS_MAJOR:*)     PE_CHECK_OS_MAJOR=${_line#OS_MAJOR:} ;;
            OS_MINOR:*)     PE_CHECK_OS_MINOR=${_line#OS_MINOR:} ;;
            SUBSYS_MAJOR:*) PE_CHECK_SUBSYS_MAJOR=${_line#SUBSYS_MAJOR:} ;;
            SUBSYS_MINOR:*) PE_CHECK_SUBSYS_MINOR=${_line#SUBSYS_MINOR:} ;;
            REASON:*)
                _v=${_line#REASON:}
                if [ -n "$PE_CHECK_FAIL_REASON" ]; then
                    PE_CHECK_FAIL_REASON="$PE_CHECK_FAIL_REASON; $_v"
                else
                    PE_CHECK_FAIL_REASON=$_v
                fi
                ;;
            RESULT:pass) _result=pass ;;
            RESULT:fail) _result=fail ;;
        esac
    done <"$_tmpdir/awk-out"

    rm -rf "$_tmpdir"

    if [ "${_result:-pass}" = "fail" ]; then
        PE_CHECK_RESULT="fail"
        return 1
    fi
    PE_CHECK_RESULT="pass"
    return 0
}

# ----------------------------------------------------------------------------
# CLI dispatch. Run only when invoked directly (not sourced).
# Detection: bash sets BASH_SOURCE; comparison against $0 means CLI. In other
# shells BASH_SOURCE is unset, so we match $0's basename against the script's
# known names — works when invoked as `sh pe-win98-check.posix.sh` or via the
# bin/ wrapper. (If neither path applies, we just don't run main — safe.)
# ----------------------------------------------------------------------------
_pe_check_is_cli=0
if [ -n "${BASH_SOURCE:-}" ]; then
    if [ "$BASH_SOURCE" = "$0" ]; then _pe_check_is_cli=1; fi
else
    case "${0##*/}" in
        pe-win98-check|pe-win98-check.sh|pe-win98-check.posix.sh)
            _pe_check_is_cli=1
            ;;
    esac
fi

if [ "$_pe_check_is_cli" = "1" ]; then
    if [ $# -eq 0 ]; then
        printf 'Usage: %s <exe> [<exe2> ...]\n' "$(basename -- "$0")" >&2
        exit 1
    fi

    _overall=0
    for _exe in "$@"; do
        pe_check_win98 "$_exe"
        _rc=$?
        case "$_rc" in
            0)
                _ver=""
                [ -n "$PE_CHECK_OS_MAJOR" ] && _ver="$_ver  OS=$PE_CHECK_OS_MAJOR.${PE_CHECK_OS_MINOR:-0}"
                [ -n "$PE_CHECK_SUBSYS_MAJOR" ] && _ver="$_ver  Subsys=$PE_CHECK_SUBSYS_MAJOR.${PE_CHECK_SUBSYS_MINOR:-0}"
                printf '[PASS] %s%s\n' "$_exe" "$_ver"
                ;;
            1)
                printf '[FAIL] %s — %s\n' "$_exe" "$PE_CHECK_FAIL_REASON"
                _overall=1
                ;;
            2)
                printf '[SKIP] %s (not a PE or objdump failed)\n' "$_exe"
                ;;
        esac
    done
    exit "$_overall"
fi
