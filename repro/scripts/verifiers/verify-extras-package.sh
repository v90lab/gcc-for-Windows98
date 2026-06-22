#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# verify-extras-package.sh — verify the extras-toolset directory or tarball
# ============================================================================
# Two-mode (mirrors verify-native-package.sh):
#   * directory mode — scans out/extras-toolset/ directly
#   * artifact mode  — extracts gcc-win98-native-toolchain-extras.zip to a tmpdir, scans that
#
# Checks:
#   1. Required tools are present (busybox.exe, sh.exe, make.exe,
#      ctags.exe, diff.exe, patch.exe, gdb.exe, muon.exe).
#   2. Every .exe / .dll passes the Win98 PE compatibility check via
#      pe_check_win98 (no UCRT/api-ms-win/vcruntime imports, MajorOSVersion ≤ 4).
# ============================================================================

REPRO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$REPRO_ROOT/out/package"
ARTIFACT_PATH="$PACKAGE_DIR/gcc-win98-native-toolchain-extras.zip"
EXTRAS_DIR="$REPRO_ROOT/out/extras-toolset"

source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/pe-win98-check.sh"

VERIFY_MODE=""
SCAN_ROOT=""

if [[ -d "$EXTRAS_DIR" ]]; then
    VERIFY_MODE="directory"
    SCAN_ROOT="$EXTRAS_DIR"
    echo "Verifying extras toolset directory: $EXTRAS_DIR"
elif [[ -f "$ARTIFACT_PATH" ]]; then
    VERIFY_MODE="artifact"
    echo "Verifying extras package artifact: $ARTIFACT_PATH"
else
    echo "ERROR: Neither extras directory nor package artifact found"
    echo "  Expected one of:"
    echo "    $EXTRAS_DIR"
    echo "    $ARTIFACT_PATH"
    exit 1
fi

REQUIRED_PATHS=(
    "bin/busybox.exe"
    "bin/sh.exe"
    "bin/make.exe"
    "bin/ctags.exe"
    "bin/diff.exe"
    "bin/patch.exe"
    "bin/gdb.exe"
    "bin/muon.exe"
    "bin/jq.exe"
)

if [[ "$VERIFY_MODE" == "directory" ]]; then
    has_path() {
        local rel="$1"
        [[ -e "$SCAN_ROOT/$rel" ]]
    }
else
    # zip has no hardlink/symlink concept — every path is stored as full
    # content — so the FAT32-stub failure mode we hit with .tar.xz can't
    # happen here.
    FILE_LIST=$(unzip -Z1 "$ARTIFACT_PATH")
    ROOT_PREFIX=""
    TOP_LEVELS=$(printf '%s\n' "$FILE_LIST" | awk -F/ 'NF { print $1 }' | sort -u)
    TOP_LEVEL_COUNT=$(printf '%s\n' "$TOP_LEVELS" | sed '/^$/d' | wc -l)
    if [[ "$TOP_LEVEL_COUNT" -eq 1 ]]; then
        ROOT_PREFIX="$(printf '%s\n' "$TOP_LEVELS" | head -n1)/"
    fi

    has_path() {
        local rel="$1"
        printf '%s\n' "$FILE_LIST" | awk -v rel="$rel" -v prefix="$ROOT_PREFIX" '
            $0 == rel { found = 1 }
            prefix != "" && $0 == prefix rel { found = 1 }
            END { exit(found ? 0 : 1) }
        '
    }
fi

for p in "${REQUIRED_PATHS[@]}"; do
    if has_path "$p"; then
        echo "  [OK] $p"
    else
        echo "  [MISSING] $p"
        exit 1
    fi
done

if [[ "$VERIFY_MODE" == "artifact" ]]; then
    TMPDIR_EXTRAS=$(mktemp -d)
    cleanup() {
        rm -rf "$TMPDIR_EXTRAS"
    }
    trap cleanup EXIT

    unzip -q -d "$TMPDIR_EXTRAS" "$ARTIFACT_PATH"
    SCAN_ROOT="$TMPDIR_EXTRAS"
fi

PE_TOTAL=$(find "$SCAN_ROOT" -type f \( -iname '*.exe' -o -iname '*.dll' \) | wc -l)
echo "Running Win98 PE compatibility checks across $PE_TOTAL extras binaries..."
PE_PASS=0
PE_FAIL=0
PE_N=0

# bcrypt.dll is shipped in this package as a shim (BCryptGenRandom only) so
# gdb.exe's libstdc++ random_device import resolves on Win98. Tell the PE
# checker to treat it as bundled — the shim itself still goes through the
# full check below on its own merits (msvcrt + kernel32 imports only).
export PE_CHECK_BUNDLED_DLLS="bcrypt.dll"

while IFS= read -r pe_path; do
    PE_N=$((PE_N + 1))
    # `|| true` so set -e doesn't kill us on rc=1 before we get to the
    # case — PE_CHECK_RESULT carries the verdict; we still print and tally.
    pe_check_win98 "$pe_path" || true
    case "$PE_CHECK_RESULT" in
        pass)
            (( PE_PASS++ )) || true
            ;;
        fail)
            rel_path="${pe_path#"$SCAN_ROOT"/}"
            echo "  [WIN98-FAIL] $rel_path -- $PE_CHECK_FAIL_REASON"
            (( PE_FAIL++ )) || true
            ;;
        skip)
            ;;
    esac
    # Progress every 25 files; the final iteration always prints so the
    # last partial bucket isn't silent. Failures get their own line above
    # so the progress line doesn't bury them.
    if (( PE_N % 25 == 0 )) || (( PE_N == PE_TOTAL )); then
        printf '  [%d/%d] checked (%d pass, %d fail)\n' \
            "$PE_N" "$PE_TOTAL" "$PE_PASS" "$PE_FAIL"
    fi
done < <(find "$SCAN_ROOT" -type f \( -iname '*.exe' -o -iname '*.dll' \) | sort)

if [[ "$PE_FAIL" -gt 0 ]]; then
    echo "Extras package verification: FAIL"
    echo "  Win98 PE check failed for $PE_FAIL binary file(s)"
    exit 1
fi

echo "  [OK] Win98 PE checks passed for $PE_PASS binary file(s)"

if [[ "$VERIFY_MODE" == "artifact" ]]; then
    SHA256=$(sha256sum "$ARTIFACT_PATH" | awk '{print $1}')
    SIZE=$(stat -c%s "$ARTIFACT_PATH")

    echo "Extras package verification: PASS"
    echo "  SHA256: $SHA256"
    echo "  Size: $SIZE bytes"
else
    echo "Extras toolset directory verification: PASS"
fi

mark_done verify-extras-package
