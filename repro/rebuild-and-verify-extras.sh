#!/usr/bin/env bash
# ============================================================================
# rebuild-and-verify-extras.sh — one-off helper for the Win98 missing-imports
# rebuild pass.
#
# Steps:
#   1. Clear the sentinel files for the build steps the recent patches touched.
#   2. Run ./build.sh (resumable — Ctrl-C is safe).
#   3. After build.sh exits clean, objdump the rebuilt binaries to confirm
#      each previously-failing import is gone.
#
# Throwaway. Delete after the pass succeeds.
# ============================================================================
set -euo pipefail

REPRO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$REPRO_DIR/docker-compose.yml"

# Matches STATUS_SCOPE default in scripts/lib/common.sh:
#   STATUS_SCOPE="${TARGET}__m${MATRIX}"  with TARGET=i686-w64-mingw32, MATRIX=0
STATUS_SCOPE="${STATUS_SCOPE:-i686-w64-mingw32__m0}"

SENTINELS=(
    prepare-mingw-w64
    build-mingw-w64
    build-win98-compat
    package
    write-toolchain-manifest-v2
    build-native-mingw-w64
    build-native-binutils
    verify-native-compiler-features
    verify-native-win98-capability
    package-native-toolset
    write-native-toolchain-manifest-v2
    build-native-busybox
    build-native-ctags
    build-native-make
    build-native-diffutils
    build-native-patch
    build-native-muon
    build-native-gdb
    build-bcrypt-shim
    verify-extras-package
    package-extras-toolset
    write-extras-toolchain-manifest-v2
)

SECONDS=0

# --- Step 1: Clear sentinels ------------------------------------------------
echo
echo "==============================================="
echo "STEP 1/3: Clearing sentinels in builder volume"
echo "==============================================="
RM_CMD=""
for s in "${SENTINELS[@]}"; do
    RM_CMD+="rm -fv /work/out/.status-${STATUS_SCOPE}-$s; "
done
docker compose -f "$COMPOSE_FILE" exec -T toolchain-builder bash -c "$RM_CMD"

# --- Step 2: Run build.sh ---------------------------------------------------
echo
echo "==============================================="
echo "STEP 2/3: Running ./build.sh (resumable)"
echo "==============================================="
echo "  Live output follows. ~35–45 min wall clock from cold."
echo
cd "$REPRO_DIR"
./build.sh

# --- Step 3: Verify imports -------------------------------------------------
echo
echo "==============================================="
echo "STEP 3/3: Verifying missing imports are gone"
echo "==============================================="
docker compose -f "$COMPOSE_FILE" exec -T toolchain-builder bash -c '
set -u
OBJDUMP=/work/out/toolchain/bin/i686-w64-mingw32-objdump
TS=/work/out/native-toolset/bin
EX=/work/out/extras-toolset/bin

PASS=0
FAIL=0
SKIP=0

check() {
    local label=$1 path=$2 sym=$3
    if [[ ! -f "$path" ]]; then
        printf "  [SKIP] %-30s missing %s\n" "$label" "(binary not produced)"
        SKIP=$((SKIP+1))
        return
    fi
    # objdump prints each import as "<vma>\t<ord>  <name>"; -E " $sym\$" anchors
    # on the trailing-whitespace + symbol + EOL so we don'\''t false-match on
    # substrings (e.g. _gmtime64 vs _gmtime64_s).
    if "$OBJDUMP" -p "$path" 2>/dev/null | grep -qE "[[:space:]]$sym\$"; then
        printf "  [FAIL] %-30s still imports %s\n" "$label" "$sym"
        FAIL=$((FAIL+1))
    else
        printf "  [OK]   %-30s clean of %s\n" "$label" "$sym"
        PASS=$((PASS+1))
    fi
}

echo "--- gdb / gdbserver ---"
check "toolset/gdbserver.exe" "$TS/gdbserver.exe" GetSystemWow64DirectoryA
check "toolset/gdbserver.exe" "$TS/gdbserver.exe" GetFinalPathNameByHandleA
check "extras/gdbserver.exe"  "$EX/gdbserver.exe" GetSystemWow64DirectoryA
check "extras/gdbserver.exe"  "$EX/gdbserver.exe" GetFinalPathNameByHandleA
check "extras/gdb.exe"        "$EX/gdb.exe"       GetSystemWow64DirectoryA
check "extras/gdb.exe"        "$EX/gdb.exe"       GetFinalPathNameByHandleA

echo "--- muon ---"
check "extras/muon.exe"       "$EX/muon.exe"      GetLogicalProcessorInformation

echo "--- busybox ---"
check "extras/busybox.exe"    "$EX/busybox.exe"   CheckTokenMembership
check "extras/busybox.exe"    "$EX/busybox.exe"   OpenProcessToken
check "extras/busybox.exe"    "$EX/busybox.exe"   GetTokenInformation

echo "--- make ---"
check "extras/make.exe"       "$EX/make.exe"      FindFirstVolumeW
check "extras/make.exe"       "$EX/make.exe"      FindNextVolumeW
check "extras/make.exe"       "$EX/make.exe"      FindVolumeClose

echo "--- diff ---"
check "extras/diff.exe"       "$EX/diff.exe"      _gmtime64
check "extras/diff.exe"       "$EX/diff.exe"      _localtime64
check "extras/diff.exe"       "$EX/diff.exe"      _mkgmtime64

echo
echo "=== verify summary: $PASS passed, $FAIL failed, $SKIP skipped ==="
exit $(( FAIL > 0 ? 1 : 0 ))
'

ELAPSED=$SECONDS
printf "\nTotal wall clock: %dm %ds\n" $((ELAPSED/60)) $((ELAPSED%60))
echo "Done."
