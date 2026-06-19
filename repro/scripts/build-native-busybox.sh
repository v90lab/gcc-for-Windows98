#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# build-native-busybox.sh - Build busybox-w32 for the extras toolset
# ============================================================================
# Produces a single busybox.exe (statically linked against msvcrt via the
# cross toolchain) plus a sh.exe copy so GNU make can default SHELL=sh.exe
# on Windows 98.
#
# busybox-w32 uses Kconfig + plain Makefile (no autoconf). The mingw32
# defconfig from the pinned commit is checked into repro/configs/ so the
# build is reproducible across busybox commit bumps.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

REPO_ROOT="$ROOT_DIR"
BUSYBOX_SRC="$REPO_ROOT/src/busybox-w32"
INSTALL_DIR="$REPO_ROOT/out/extras-toolset"
CROSS_BIN_DIR="$REPO_ROOT/out/toolchain/bin"
CONFIG_SRC="$REPO_ROOT/configs/busybox-w32.config"

skip_if_done build-native-busybox

# === STEP 1: Verify prerequisites ===
require_dir "$BUSYBOX_SRC" "Missing busybox-w32 sources at $BUSYBOX_SRC (run fetch-sources.sh)"
require_dir "$CROSS_BIN_DIR" "Cross toolchain not found at $CROSS_BIN_DIR"
require_file "$CONFIG_SRC" "Missing checked-in config at $CONFIG_SRC"
require_executable "$CROSS_BIN_DIR/${TARGET}-gcc" "Missing $TARGET-gcc in $CROSS_BIN_DIR"

# === STEP 2: Put cross compiler on PATH ===
export PATH="$CROSS_BIN_DIR:$PATH"

# === STEP 3: Install the pinned config and reconcile ===
log "installing pinned busybox-w32 config"
cp "$CONFIG_SRC" "$BUSYBOX_SRC/.config"

cd "$BUSYBOX_SRC"
# `olddefconfig` isn't exposed by busybox-w32's Kconfig at this pin; feed
# `oldconfig` a finite stream of newlines so any new prompts take the default.
# An infinite producer (e.g. `yes ""`) would get SIGPIPE'd when make closes its
# stdin and pipefail would surface that as 141 even though oldconfig succeeded.
printf '\n%.0s' {1..2000} | run_logged build-native-busybox.log \
    make oldconfig CROSS_COMPILE="${TARGET}-"

# === STEP 4: Build ===
# Pass Win98-host flags via EXTRA_CFLAGS/EXTRA_LDFLAGS (Kbuild appends these
# to its own CFLAGS/LDFLAGS, so they don't clobber busybox's settings).
log "building busybox-w32 (target=$TARGET)"
run_logged build-native-busybox.log \
    make -j"$JOBS" CROSS_COMPILE="${TARGET}-" \
        EXTRA_CFLAGS="$WIN98_TARGET_CPPFLAGS" \
        EXTRA_LDFLAGS="$WIN98_TARGET_LDFLAGS"

require_file "$BUSYBOX_SRC/busybox.exe" "busybox-w32 build produced no busybox.exe"

# === STEP 5: Install ===
mkdir -p "$INSTALL_DIR/bin"
cp -v "$BUSYBOX_SRC/busybox.exe" "$INSTALL_DIR/bin/busybox.exe"

# Provide sh.exe so GNU make recipes pick up an ash shell by default.
# busybox dispatches on argv[0] when a copy/symlink uses an applet name.
cp -v "$BUSYBOX_SRC/busybox.exe" "$INSTALL_DIR/bin/sh.exe"

mark_done build-native-busybox
log "busybox-w32 build complete"
