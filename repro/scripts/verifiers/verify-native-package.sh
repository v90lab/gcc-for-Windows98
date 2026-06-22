#!/usr/bin/env bash
set -euo pipefail

REPRO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$REPRO_ROOT/out/package"
ARTIFACT_PATH="$PACKAGE_DIR/gcc-win98-native-toolchain.zip"
NATIVE_DIR="$REPRO_ROOT/out/native-toolset"

source "$SCRIPT_DIR/pe-win98-check.sh"

VERIFY_MODE=""
SCAN_ROOT=""

if [[ -d "$NATIVE_DIR" ]]; then
    VERIFY_MODE="directory"
    SCAN_ROOT="$NATIVE_DIR"
    echo "Verifying native toolset directory: $NATIVE_DIR"
elif [[ -f "$ARTIFACT_PATH" ]]; then
    VERIFY_MODE="artifact"
    echo "Verifying native package artifact: $ARTIFACT_PATH"
else
    echo "ERROR: Neither native directory nor package artifact found"
    echo "  Expected one of:"
    echo "    $NATIVE_DIR"
    echo "    $ARTIFACT_PATH"
    exit 1
fi

# Confirm required paths from the current packaged layout.
# The archive may either be rooted directly or under a single top-level folder
# such as gcc_win98/.
REQUIRED_PATHS=(
    "bin/gcc.exe"
    "bin/g++.exe"
    "bin/ar.exe"
    "bin/ld.exe"
    "i686-w64-mingw32/include/stdio.h"
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
    TMPDIR_NATIVE=$(mktemp -d)
    cleanup() {
        rm -rf "$TMPDIR_NATIVE"
    }
    trap cleanup EXIT

    unzip -q -d "$TMPDIR_NATIVE" "$ARTIFACT_PATH"
    SCAN_ROOT="$TMPDIR_NATIVE"
fi

check_no_prereq_runtime_imports() {
    local exe_path="$1"
    if objdump -p "$exe_path" 2>/dev/null | grep -Eiq 'DLL Name: .*(gmp|mpfr|mpc)'; then
        echo "  [UNEXPECTED-RUNTIME-DEP] $exe_path imports GMP/MPFR/MPC"
        exit 1
    fi
    echo "  [OK] no GMP/MPFR/MPC runtime imports in ${exe_path#$SCAN_ROOT/}"
}

while IFS= read -r exe_path; do
    check_no_prereq_runtime_imports "$exe_path"
done < <(find "$SCAN_ROOT" -type f \( -name 'gcc.exe' -o -name 'g++.exe' \) | sort)

PE_TOTAL=$(find "$SCAN_ROOT" -type f \( -iname '*.exe' -o -iname '*.dll' \) | wc -l)
echo "Running Win98 PE compatibility checks across $PE_TOTAL extracted binaries..."
PE_PASS=0
PE_FAIL=0
PE_N=0

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
    echo "Native package verification: FAIL"
    echo "  Win98 PE check failed for $PE_FAIL binary file(s)"
    exit 1
fi

echo "  [OK] Win98 PE checks passed for $PE_PASS binary file(s)"

if [[ "$VERIFY_MODE" == "artifact" ]]; then
    SHA256=$(sha256sum "$ARTIFACT_PATH" | awk '{print $1}')
    SIZE=$(stat -c%s "$ARTIFACT_PATH")

    echo "Native package verification: PASS"
    echo "  SHA256: $SHA256"
    echo "  Size: $SIZE bytes"
else
    echo "Native toolset directory verification: PASS"
fi
