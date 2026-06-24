#!/bin/sh
# ============================================================================
# pe-ldd.sh — PE dependency walker for Win98 (ldd / lddtree analog)
# ============================================================================
# Lists the shared library imports of a PE binary and reports where (or
# whether) each one would resolve under Win98's DLL search order. The primary
# use case is "did I forget to put DLL X on PATH?" — system DLLs are reported
# as such without a path so the actual gap stands out.
#
# Runs unmodified under bash (Linux dev box / cross-toolchain), busybox-w32
# ash (Win98 extras toolset), and dash. Same script ships in both the cross
# tarball's bin/ + share/win98-verify/ and the extras zip's share/win98-verify/.
#
# Invocation:
#   pe-ldd     [opts] <exe>...   — direct imports only (default)
#   pe-lddtree [opts] <exe>...   — recursive (same script, basename detection)
#
# Options:
#   -r, --recursive       Recurse into found non-system DLLs (cycle-safe).
#   -u, --unresolved      Print only DLLs that couldn't be located.
#   -h, --help            Show usage.
#
# Search order (mirrors Win98 PE loader):
#   1. Directory of the input binary (App Directory)
#   2. PATH (`;`-separated on Windows, `:` elsewhere — sniffed via $SYSTEMROOT)
# Current directory + system dirs are intentionally NOT searched: the loader
# DOES check them, but they're noise for "is anything missing" inspection.
# System DLLs (per the bundled Win98 SE allowlist) are reported as
# "(Win98 system DLL)" without a path lookup.
#
# Exit codes:
#   0  every non-system DLL resolved
#   1  at least one DLL not found
#   2  bad invocation / objdump unavailable / not a PE
#
# Environment:
#   OBJDUMP            objdump binary to use (default: probe PATH for
#                      `objdump` then `i686-w64-mingw32-objdump`)
#   PE_LDD_ALLOWLIST   path to win98se-api-allowlist.json
#                      (default: auto-resolved relative to this script;
#                      empty string disables system-DLL classification)
# ============================================================================

# Don't `set -e` / `set -u` — script may be invoked under shells with their
# own option preferences, and we handle our own error checking.

# ----------------------------------------------------------------------------
# Self-location for allowlist auto-resolve. Same pattern as pe-win98-check.sh:
# bash sets BASH_SOURCE, ash/dash use $0; no readlink in busybox, so the
# bin/-wrapper-symlink case is handled by an explicit ../share/win98-verify/
# probe rather than walking the symlink.
# ----------------------------------------------------------------------------
_pe_ldd_self="${BASH_SOURCE:-$0}"
_pe_ldd_self_dir=$(cd -P "$(dirname "$_pe_ldd_self")" 2>/dev/null && pwd)

_pe_ldd_resolve_allowlist() {
    if [ -n "${PE_LDD_ALLOWLIST+x}" ]; then
        # Explicit override (including empty string for "disable").
        printf '%s\n' "$PE_LDD_ALLOWLIST"
        return
    fi
    if [ -z "$_pe_ldd_self_dir" ]; then
        printf '%s\n' ""
        return
    fi
    # Repo layout: scripts/verifiers/<this> + ../../data/<file>
    if [ -f "$_pe_ldd_self_dir/../../data/win98se-api-allowlist.json" ]; then
        printf '%s\n' "$_pe_ldd_self_dir/../../data/win98se-api-allowlist.json"
        return
    fi
    # Flat installed layout: share/win98-verify/<this> + share/win98-verify/<file>
    if [ -f "$_pe_ldd_self_dir/win98se-api-allowlist.json" ]; then
        printf '%s\n' "$_pe_ldd_self_dir/win98se-api-allowlist.json"
        return
    fi
    # Cross-tarball bin/ wrapper layout: bin/pe-ldd is a symlink onto
    # ../share/win98-verify/pe-ldd.sh; without readlink we can't follow, so
    # probe the share/ neighbor explicitly.
    if [ -f "$_pe_ldd_self_dir/../share/win98-verify/win98se-api-allowlist.json" ]; then
        printf '%s\n' "$_pe_ldd_self_dir/../share/win98-verify/win98se-api-allowlist.json"
        return
    fi
    printf '%s\n' ""
}

ALLOWLIST=$(_pe_ldd_resolve_allowlist)

# ----------------------------------------------------------------------------
# PATH separator. Windows (cmd/command.com/busybox-w32) uses ';', POSIX ':'.
# $SYSTEMROOT is set on every Windows version including 9x; $WINDIR is the
# legacy fallback. Either presence forces ';'.
# ----------------------------------------------------------------------------
if [ -n "${SYSTEMROOT:-}" ] || [ -n "${WINDIR:-}" ]; then
    PATH_SEP=';'
else
    PATH_SEP=':'
fi

# ----------------------------------------------------------------------------
# objdump probe. Mirrors pe-win98-check.sh. The OBJDUMP env override wins.
# ----------------------------------------------------------------------------
_pe_ldd_find_objdump() {
    if [ -n "${OBJDUMP:-}" ] && command -v "$OBJDUMP" >/dev/null 2>&1; then
        printf '%s\n' "$OBJDUMP"; return 0
    fi
    if command -v objdump >/dev/null 2>&1; then
        printf '%s\n' "objdump"; return 0
    fi
    if command -v i686-w64-mingw32-objdump >/dev/null 2>&1; then
        printf '%s\n' "i686-w64-mingw32-objdump"; return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# System-DLL set. Loaded once from the allowlist JSON into a tempfile of
# lowercase basenames (one per line). Fast lookup via `grep -Fxq`. If jq isn't
# available or the allowlist is missing, fall back to a hardcoded shortlist of
# the obvious ones — degraded mode prints a one-shot warning to stderr.
# ----------------------------------------------------------------------------
SYSTEM_DLL_FILE=""
_PE_LDD_WARNED_DEGRADED=

_pe_ldd_warn_degraded_once() {
    [ -n "$_PE_LDD_WARNED_DEGRADED" ] && return
    _PE_LDD_WARNED_DEGRADED=1
    printf '[WARN] pe-ldd: %s\n' "$1" >&2
    printf '[WARN] pe-ldd: system-DLL classification uses a small builtin list; a Win98 system DLL not on that list will be reported as missing.\n' >&2
}

_pe_ldd_load_system_dlls() {
    [ -z "$ALLOWLIST" ] && {
        # Caller opted out explicitly — no warning.
        return
    }
    if [ ! -f "$ALLOWLIST" ]; then
        _pe_ldd_warn_degraded_once "allowlist not found at $ALLOWLIST"
        return
    fi
    if ! command -v jq >/dev/null 2>&1; then
        _pe_ldd_warn_degraded_once "jq not available on PATH (required to parse the allowlist)"
        return
    fi
    SYSTEM_DLL_FILE=$(mktemp 2>/dev/null) || {
        _pe_ldd_warn_degraded_once "mktemp failed"
        SYSTEM_DLL_FILE=""
        return
    }
    if ! jq -r '.dlls // {} | keys[]' "$ALLOWLIST" 2>/dev/null \
            | tr 'A-Z' 'a-z' \
            > "$SYSTEM_DLL_FILE" 2>/dev/null; then
        _pe_ldd_warn_degraded_once "failed to parse $ALLOWLIST"
        rm -f "$SYSTEM_DLL_FILE"
        SYSTEM_DLL_FILE=""
        return
    fi
    if [ ! -s "$SYSTEM_DLL_FILE" ]; then
        _pe_ldd_warn_degraded_once "allowlist parsed empty"
        rm -f "$SYSTEM_DLL_FILE"
        SYSTEM_DLL_FILE=""
    fi
}

# ----------------------------------------------------------------------------
# Per-input visited set for recursive mode (tempfile of lowercase basenames).
# ----------------------------------------------------------------------------
VISITED_FILE=""

_pe_ldd_cleanup() {
    [ -n "$SYSTEM_DLL_FILE" ] && rm -f "$SYSTEM_DLL_FILE"
    [ -n "$VISITED_FILE" ] && rm -f "$VISITED_FILE"
}
trap _pe_ldd_cleanup EXIT INT TERM HUP

_pe_ldd_mark_visited() {
    printf '%s\n' "$1" >> "$VISITED_FILE"
}

_pe_ldd_is_visited() {
    [ -n "$VISITED_FILE" ] || return 1
    grep -Fxq "$1" "$VISITED_FILE" 2>/dev/null
}

_pe_ldd_is_system_dll() {
    name_lc=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
    if [ -n "$SYSTEM_DLL_FILE" ]; then
        grep -Fxq "$name_lc" "$SYSTEM_DLL_FILE" 2>/dev/null
        return $?
    fi
    # Degraded fallback — the heavy hitters only. If a binary imports
    # something Win98-shipped not on this list (rare; nlsfunc / dciman32 /
    # winspool / version), it'll be reported as missing — the degraded-mode
    # warning above tells the user this can happen.
    case "$name_lc" in
        kernel32.dll|user32.dll|gdi32.dll|msvcrt.dll|advapi32.dll|\
        ws2_32.dll|wsock32.dll|ole32.dll|oleaut32.dll|shell32.dll|\
        comctl32.dll|comdlg32.dll|winmm.dll|version.dll|crtdll.dll|\
        rpcrt4.dll|mpr.dll|winspool.drv|mswsock.dll|wininet.dll|\
        setupapi.dll|dciman32.dll|nlsfunc.exe)
            return 0 ;;
    esac
    return 1
}

# ----------------------------------------------------------------------------
# get_imports <exe>
# Emits unique DLL basenames (preserving objdump's casing on first occurrence)
# from both Import Tables and Delay Import Tables.
# ----------------------------------------------------------------------------
_pe_ldd_get_imports() {
    "$OBJDUMP_BIN" -p "$1" 2>/dev/null | awk '
        /DLL Name:/ {
            name = $3
            sub(/\r$/, "", name)
            key = tolower(name)
            if (!(key in seen)) {
                seen[key] = 1
                print name
            }
        }
    '
}

# ----------------------------------------------------------------------------
# search_dll <basename> <app_dir>
# App Dir, then PATH. Three casings tried per directory (as-given / lower /
# upper) for Linux case-sensitive FS friendliness; FAT32 ignores case anyway.
# ----------------------------------------------------------------------------
_pe_ldd_search_dll() {
    dll=$1
    app_dir=$2
    dll_lc=$(printf '%s' "$dll" | tr 'A-Z' 'a-z')
    dll_uc=$(printf '%s' "$dll" | tr 'a-z' 'A-Z')

    # App directory
    if [ -n "$app_dir" ]; then
        for try in "$dll" "$dll_lc" "$dll_uc"; do
            if [ -f "$app_dir/$try" ]; then
                printf '%s\n' "$app_dir/$try"
                return 0
            fi
        done
    fi

    # PATH walk
    OLD_IFS=$IFS
    IFS=$PATH_SEP
    set -f  # avoid glob expansion of PATH entries
    for d in $PATH; do
        set +f
        IFS=$OLD_IFS
        [ -z "$d" ] && { IFS=$PATH_SEP; set -f; continue; }
        # Strip a single trailing slash/backslash
        case "$d" in
            *[/\\]) d=${d%?} ;;
        esac
        for try in "$dll" "$dll_lc" "$dll_uc"; do
            if [ -f "$d/$try" ]; then
                printf '%s\n' "$d/$try"
                return 0
            fi
        done
        IFS=$PATH_SEP
        set -f
    done
    set +f
    IFS=$OLD_IFS
    return 1
}

# ----------------------------------------------------------------------------
# walk_one <file> <indent> <app_dir>
# Sets RESULT_FAILED=1 on the first not-found non-system DLL.
# In recursive mode, _pe_ldd_mark_visited / _pe_ldd_is_visited gate recursion.
# Cycle hits are reported as "(already shown)" unless --unresolved is in effect.
#
# All locals must be declared `local` — without that, the recursive call
# would clobber the parent's `indent` / `app_dir` (POSIX sh assigns globally
# inside functions), causing post-recursion siblings to print at the inner
# indent. busybox ash + bash both support `local`; dash also supports it as
# an extension (the man page hedges but every dash since 2003 has it).
# ----------------------------------------------------------------------------
walk_one() {
    local exe=$1
    local indent=$2
    local app_dir=$3
    local imports dll dll_lc resolved

    imports=$(_pe_ldd_get_imports "$exe")
    [ -z "$imports" ] && return

    # imports is whitespace-separated. Iterating without quoting is correct
    # here (DLL basenames don't contain whitespace).
    for dll in $imports; do
        dll_lc=$(printf '%s' "$dll" | tr 'A-Z' 'a-z')

        if [ "$RECURSIVE" = 1 ] && _pe_ldd_is_visited "$dll_lc"; then
            if [ "$UNRESOLVED_ONLY" = 0 ]; then
                printf '%s%s (already shown)\n' "$indent" "$dll"
            fi
            continue
        fi
        [ "$RECURSIVE" = 1 ] && _pe_ldd_mark_visited "$dll_lc"

        if _pe_ldd_is_system_dll "$dll"; then
            if [ "$UNRESOLVED_ONLY" = 0 ]; then
                printf '%s%s => (Win98 system DLL)\n' "$indent" "$dll"
            fi
            continue
        fi

        resolved=$(_pe_ldd_search_dll "$dll" "$app_dir")
        if [ -n "$resolved" ]; then
            if [ "$UNRESOLVED_ONLY" = 0 ]; then
                printf '%s%s => %s\n' "$indent" "$dll" "$resolved"
            fi
            if [ "$RECURSIVE" = 1 ]; then
                walk_one "$resolved" "${indent}    " "$app_dir"
            fi
        else
            printf '%s%s => not found\n' "$indent" "$dll"
            RESULT_FAILED=1
        fi
    done
}

# ----------------------------------------------------------------------------
# Argument parsing + dispatch.
# ----------------------------------------------------------------------------
RECURSIVE=0
UNRESOLVED_ONLY=0

# Self-name → default behavior. Strip both `/` and `\` so the busybox-w32
# invocation `sh share\win98-verify\pe-ldd.sh` is handled too.
_pe_ldd_basename=${0##*/}
_pe_ldd_basename=${_pe_ldd_basename##*\\}
case "$_pe_ldd_basename" in
    *lddtree*) RECURSIVE=1 ;;
esac

show_help() {
    cat <<EOF
Usage: ${_pe_ldd_basename:-pe-ldd} [options] <exe> [<exe2>...]

Report shared library dependencies of PE binaries (Win98 ldd analog).
Each direct import is reported as resolved to a path, "(Win98 system DLL)",
or "not found". Use -r for transitive deps (or invoke as pe-lddtree).

Options:
  -r, --recursive       Recurse into found non-system DLLs.
  -u, --unresolved      Print only DLLs that couldn't be located.
  -h, --help            Show this help.

Exit codes:
  0  every non-system DLL resolved
  1  at least one DLL not found
  2  bad invocation / objdump unavailable / not a PE
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--recursive)   RECURSIVE=1; shift ;;
        -u|--unresolved|--unresolved-only) UNRESOLVED_ONLY=1; shift ;;
        -h|--help)        show_help; exit 0 ;;
        --)               shift; break ;;
        -*)
            printf 'pe-ldd: unknown option: %s (try --help)\n' "$1" >&2
            exit 2 ;;
        *) break ;;
    esac
done

if [ $# -eq 0 ]; then
    printf 'pe-ldd: no input files (try --help)\n' >&2
    exit 2
fi

OBJDUMP_BIN=$(_pe_ldd_find_objdump) || {
    printf 'pe-ldd: objdump not found on PATH (need objdump or i686-w64-mingw32-objdump)\n' >&2
    exit 2
}

_pe_ldd_load_system_dlls

OVERALL=0
MULTIPLE=0
[ $# -gt 1 ] && MULTIPLE=1
FIRST=1

for exe in "$@"; do
    if [ ! -f "$exe" ]; then
        printf 'pe-ldd: %s: file not found\n' "$exe" >&2
        OVERALL=2
        continue
    fi

    # Quick PE sniff via objdump -- skips with rc=2 on non-PE input.
    if ! "$OBJDUMP_BIN" -p "$exe" >/dev/null 2>&1; then
        printf 'pe-ldd: %s: not a PE binary (objdump failed)\n' "$exe" >&2
        OVERALL=2
        continue
    fi

    if [ "$MULTIPLE" = 1 ]; then
        [ "$FIRST" = 0 ] && printf '\n'
        printf '%s:\n' "$exe"
    fi
    FIRST=0

    # Per-input visited set.
    if [ "$RECURSIVE" = 1 ]; then
        VISITED_FILE=$(mktemp 2>/dev/null) || VISITED_FILE=""
        [ -n "$VISITED_FILE" ] && : > "$VISITED_FILE"
    fi

    # dirname doesn't handle backslashes on POSIX; cover both separators.
    app_dir=$exe
    case "$app_dir" in
        */*)  app_dir=${app_dir%/*} ;;
        *\\*) app_dir=${app_dir%\\*} ;;
        *)    app_dir="." ;;
    esac

    RESULT_FAILED=0
    walk_one "$exe" "        " "$app_dir"

    if [ -n "$VISITED_FILE" ]; then
        rm -f "$VISITED_FILE"
        VISITED_FILE=""
    fi

    if [ "$RESULT_FAILED" = 1 ] && [ "$OVERALL" = 0 ]; then
        OVERALL=1
    fi
done

exit "$OVERALL"
