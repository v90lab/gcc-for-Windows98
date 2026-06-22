#!/usr/bin/env bash
# smoke-cmake-build.sh — Phase 3 smoke test: build repro/tests with CMake+Ninja using
# either the cross or native toolchain, then verify every produced .exe is Windows 98
# compatible (no UCRT imports, PE OS version ≤ 4.10) and runs correctly under Wine.
#
# Usage: smoke-cmake-build.sh <cross|native> [jobs]
#   cross   — use /opt/cmake-toolchain/cross-toolchain.cmake
#   native  — use /opt/cmake-toolchain/native-toolchain.cmake (wine wrappers as compiler)
#
# Runs inside the consumer container (/workspace = repro/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"

TOOLCHAIN_KIND="${1:-cross}"
JOBS="${2:-$(nproc)}"

case "$TOOLCHAIN_KIND" in
    cross)
        TOOLCHAIN_FILE="/opt/cmake-toolchain/cross-toolchain.cmake"
        BUILD_DIR="/workspace/out/smoke-cross"
        # Runtime DLLs for dynamically-linked cross-compiled binaries.
        CROSS="${CROSS_PREFIX:-/opt/cross-toolchain}"
        RUNTIME_DLL_DIR="$CROSS/i686-w64-mingw32/lib"
        ;;
    native)
        TOOLCHAIN_FILE="/opt/cmake-toolchain/native-toolchain.cmake"
        BUILD_DIR="/workspace/out/smoke-native"
        NATIVE="${NATIVE_PREFIX:-/opt/native-toolset}"
        RUNTIME_DLL_DIR="$NATIVE/i686-w64-mingw32/lib"
        ;;
    *)
        die "Unknown toolchain kind: $TOOLCHAIN_KIND (expected 'cross' or 'native')"
        ;;
esac

TEST_SRC="/workspace/tests"
OUTPUT_BIN_DIR="$BUILD_DIR/out"

PASS_PE=0; FAIL_PE=0
PASS_RUN=0; FAIL_RUN=0

# ── Helper: Win98 PE import check ────────────────────────────────────────────
# The dynamic-link test variants (everything without "_static" in the name) need
# libgcc_s_dw2-1.dll / libstdc++-6.dll / libssp-0.dll / libquadmath-0.dll.
# The smoke harness ships those DLLs next to each exe via run_under_wine() — that
# is the shipping intent for the dynamic variants, so they should pass PE check
# under the §5.7 bundled-DLL escape hatch. Note this only suppresses the
# "DLL not present on Win98" check; per-function checks still run, so e.g. a
# stat-family or other-CRT regression in the bundled DLL itself would still fail.
export PE_CHECK_BUNDLED_DLLS="libgcc_s_dw2-1.dll libstdc++-6.dll libssp-0.dll libquadmath-0.dll"

check_pe_win98() {
    local exe="$1"
    local rel="${exe#$BUILD_DIR/}"

    # `|| true` so set -e doesn't kill us on rc=1 before the case runs.
    pe_check_win98 "$exe" || true
    case "$PE_CHECK_RESULT" in
        pass)
            local ver_tag=""
            [[ -n "$PE_CHECK_OS_MAJOR" ]] && ver_tag="  OS=$PE_CHECK_OS_MAJOR.${PE_CHECK_OS_MINOR:-0}"
            log "[OK-PE]   $rel$ver_tag"
            (( PASS_PE++ )) || true
            ;;
        fail)
            log "[FAIL-PE] $rel  — $PE_CHECK_FAIL_REASON"
            (( FAIL_PE++ )) || true
            ;;
        skip)
            log "[SKIP-PE] $rel  (not a PE or objdump failed)"
            ;;
    esac
}

# ── Helper: Wine execution check ─────────────────────────────────────────────
run_under_wine() {
    local exe="$1"
    local rel="${exe#$BUILD_DIR/}"

    # Wine needs runtime DLLs beside the exe or in WINEPATH.
    # Copy missing runtime DLLs to the exe's directory (idempotent).
    local exe_dir
    exe_dir="$(dirname "$exe")"
    for dll in libgcc_s_dw2-1.dll libstdc++-6.dll libssp-0.dll libquadmath-0.dll; do
        local src="$RUNTIME_DLL_DIR/$dll"
        if [[ -f "$src" && ! -f "$exe_dir/$dll" ]]; then
            cp -f "$src" "$exe_dir/$dll"
        fi
    done

    local wine_out
    local wine_rc=0
    local cross_lib="${CROSS_PREFIX:-/opt/cross-toolset}/i686-w64-mingw32/lib"
    local winepath
    # Convert Unix path to Windows-style for Wine
    winepath="Z:${cross_lib//\//\\}"
    # Run each test in a dedicated tmpdir so that any files the test writes
    # (e.g. fstream_smoke.txt) stay out of the workspace/source tree.
    local wine_tmpdir
    wine_tmpdir="$(mktemp -d)"
    wine_out=$(cd "$wine_tmpdir" && WINEPREFIX="${WINEPREFIX:-/opt/.wine}"
        WINEPATH="$winepath"
        WINEDEBUG=-all \
        wine "$exe" 2>&1) || wine_rc=$?
    rm -rf "$wine_tmpdir"

    if [[ "$wine_rc" -eq 0 ]]; then
        log "[OK-RUN]  $rel"
        (( PASS_RUN++ )) || true
    else
        log "[FAIL-RUN] $rel  — wine exit $wine_rc"
        log "  output: $(printf '%s\n' "$wine_out" | head -5)"
        (( FAIL_RUN++ )) || true
    fi
}

# ── Build ─────────────────────────────────────────────────────────────────────
log "=== CMake+Ninja build [$TOOLCHAIN_KIND toolchain] ==="
log "Source : $TEST_SRC"
log "Build  : $BUILD_DIR"
log "Toolchain file: $TOOLCHAIN_FILE"

if [[ ! -f "$TOOLCHAIN_FILE" ]]; then
    die "Toolchain file not found: $TOOLCHAIN_FILE"
fi

# Wipe the build dir on every smoke run. The smoke step only re-runs when its
# declared inputs (toolchain file, tests/CMakeLists.txt, the package manifest)
# are newer than the sentinel — meaning something material changed. CMake's
# Ninja generator does NOT reliably detect linker-flag changes in an existing
# build dir (the smoke harness's hard lesson: a toolchain-file edit that added
# `-Wl,--whole-archive -lwin98compat -Wl,--no-whole-archive` left ninja saying
# "no work to do" because the .o files were unchanged and the .exes were newer
# than them; the link rule with the stale command was never re-fired). A clean
# build is cheap here (~40 small tests in seconds) and removes the trap.
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

cmake -S "$TEST_SRC" \
      -B "$BUILD_DIR" \
      -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
      -DCMAKE_BUILD_TYPE=Release \
      --log-level=WARNING

cmake --build "$BUILD_DIR" --parallel "$JOBS"

log "Build complete. Scanning $OUTPUT_BIN_DIR/ ..."

if [[ ! -d "$OUTPUT_BIN_DIR" ]]; then
    die "Expected output directory not found: $OUTPUT_BIN_DIR"
fi

# ── Verify and run every produced .exe ───────────────────────────────────────
log "=== Win98 PE compatibility check (built binaries) ==="
while IFS= read -r -d '' exe; do
    check_pe_win98 "$exe"
done < <(find "$OUTPUT_BIN_DIR" -type f -iname "*.exe" -print0 | sort -z)

log "=== Wine execution check ==="
# Skip the wine sweep when any PE check failed. A Win98-incompatible binary
# (e.g. UCRT import, OS version > 4) can still happily run under wine on a
# modern Linux host, so green wine output here would mask the real PE failure
# — and the script's going to die at the end anyway because FAIL_PE>0 feeds
# TOTAL_FAIL. No point spending the runtime.
if (( FAIL_PE > 0 )); then
    log "[SKIP] $FAIL_PE PE failure(s) — skipping wine sweep (would not change verdict)"
else
    while IFS= read -r -d '' exe; do
        run_under_wine "$exe"
    done < <(find "$OUTPUT_BIN_DIR" -type f -iname "*.exe" -print0 | sort -z)
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "=== [$TOOLCHAIN_KIND] PE check:  $PASS_PE passed, $FAIL_PE failed ==="
if (( FAIL_PE > 0 )); then
    log "=== [$TOOLCHAIN_KIND] Wine run:  skipped (PE check failed) ==="
else
    log "=== [$TOOLCHAIN_KIND] Wine run:  $PASS_RUN passed, $FAIL_RUN failed ==="
fi

TOTAL_FAIL=$(( FAIL_PE + FAIL_RUN ))
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    die "CMake build smoke test FAILED for $TOOLCHAIN_KIND toolchain ($TOTAL_FAIL failures)"
fi
