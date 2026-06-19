#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-bcrypt-shim.sh - Build the bcrypt.dll shim for Win98 extras
# ============================================================================
# Cross-compiles repro/bcrypt-shim/bcrypt.c into bcrypt.dll and installs it
# into out/extras-toolset/bin/ alongside gdb.exe. Win98's loader's App
# Directory search finds it there before any (absent) system bcrypt.dll
# search succeeds, satisfying gdb.exe's static BCryptGenRandom import.
#
# Why this exists: libstdc++ 11's random.cc statically links against
# bcrypt!BCryptGenRandom for std::random_device. That dependency travels
# into gdb.exe via -static-libstdc++. See repro/bcrypt-shim/bcrypt.c for
# the full story.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
SHIM_SRC="$REPO_ROOT/bcrypt-shim/bcrypt.c"
BUILD_DIR="$REPO_ROOT/build/bcrypt-shim"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset/bin"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"

skip_if_done build-bcrypt-shim

require_file "$SHIM_SRC" "missing bcrypt shim source at $SHIM_SRC"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

mkdir -p "$BUILD_DIR" "$INSTALL_DIR"

log "building bcrypt.dll shim"
# --kill-at strips the @N decoration off stdcall exports so the export
# table reads "BCryptGenRandom" — what libstdc++'s import refers to —
# rather than "BCryptGenRandom@16".
#
# We deliberately do NOT pass -nostdlib: we need msvcrt's rand/srand.
# The default mingw -shared link pulls in libgcc/libmingwex but those
# don't import bcrypt themselves (verified via objdump on the result).
run_logged build-bcrypt-shim.log \
    "$CROSS_BIN_DIR/${TARGET}-gcc" \
        -shared -O2 -Wall \
        -Wl,--kill-at \
        $WIN98_TARGET_CPPFLAGS $WIN98_TARGET_LDFLAGS \
        -o "$BUILD_DIR/bcrypt.dll" \
        "$SHIM_SRC"

log "verifying shim exports and imports"
# Confirm the export is undecorated.
if ! "$CROSS_BIN_DIR/${TARGET}-objdump" -p "$BUILD_DIR/bcrypt.dll" \
        | grep -q '^\s*\[\s*[0-9]\+\] BCryptGenRandom$'; then
    "$CROSS_BIN_DIR/${TARGET}-objdump" -p "$BUILD_DIR/bcrypt.dll" | sed -n '/Export Address Table/,/^$/p'
    die "bcrypt.dll did not export an undecorated BCryptGenRandom"
fi

# Confirm the shim itself is Win98-safe (no UCRT/api-ms-win-/bcrypt loops).
log "running Win98 PE check on the shim"
source "$ROOT_DIR/scripts/verifiers/pe-win98-check.sh"
pe_check_win98 "$BUILD_DIR/bcrypt.dll" || true
if [[ "$PE_CHECK_RESULT" != "pass" ]]; then
    die "bcrypt.dll shim failed Win98 PE check: $PE_CHECK_FAIL_REASON"
fi

cp "$BUILD_DIR/bcrypt.dll" "$INSTALL_DIR/bcrypt.dll"
require_file "$INSTALL_DIR/bcrypt.dll" "bcrypt.dll install failed"

mark_done build-bcrypt-shim
log "bcrypt shim build complete"
