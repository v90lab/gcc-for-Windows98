#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# package-native-toolset.sh - Package native toolset
# ============================================================================
# Replaces the old confusing flow:
#   build-native-toolset-stage.sh (copy from non-existent paths)
#   -> package-native-toolset.sh (package from yet another path)
# New simplified flow: just package out/native-toolset directly.

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_step verify-native-compiler-features "run verify-compiler-features.sh native first"

REPO_ROOT="$ROOT_DIR"
SOURCE_DIR="$REPO_ROOT/out/native-toolset"
PACKAGE_DIR="$REPO_ROOT/out/package"
PACKAGE_NAME="gcc-win98-native-toolchain.zip"
PACKAGE_PATH="$PACKAGE_DIR/$PACKAGE_NAME"

# === Ensure libgcc.a and libgcc_s_dw2-1.dll are in target lib dir ===
LIBGCC_A_SRC="$SOURCE_DIR/lib/gcc/${TARGET}/11.1.0/libgcc.a"
LIBGCC_A_DST="$SOURCE_DIR/${TARGET}/lib/libgcc.a"
if [ -f "$LIBGCC_A_SRC" ] && [ ! -f "$LIBGCC_A_DST" ]; then
  cp -v "$LIBGCC_A_SRC" "$LIBGCC_A_DST"
fi
# Copy shared libgcc from cross toolchain if missing (same version, same platform)
SHARED_DLL_SRC="$REPO_ROOT/out/toolchain/${TARGET}/lib/libgcc_s_dw2-1.dll"
SHARED_DLL_DST="$SOURCE_DIR/${TARGET}/lib/libgcc_s_dw2-1.dll"
if [ -f "$SHARED_DLL_SRC" ] && [ ! -f "$SHARED_DLL_DST" ]; then
  cp -v "$SHARED_DLL_SRC" "$SHARED_DLL_DST"
  cp -v "$SHARED_DLL_SRC" "$SOURCE_DIR/lib/gcc/${TARGET}/11.1.0/"
fi
SHARED_A_SRC="$REPO_ROOT/out/toolchain/${TARGET}/lib/libgcc_s.a"
SHARED_A_DST="$SOURCE_DIR/${TARGET}/lib/libgcc_s.a"
if [ -f "$SHARED_A_SRC" ] && [ ! -f "$SHARED_A_DST" ]; then
  cp -v "$SHARED_A_SRC" "$SHARED_A_DST"
fi

# === Verify source exists ===
require_dir "$SOURCE_DIR/bin" "Native toolset not found at $SOURCE_DIR. Run build-native-host-gcc.sh first."

# === Create package ===
mkdir -p "$PACKAGE_DIR"
rm -f "$PACKAGE_PATH"

echo "Packaging native toolset..."
echo "  Source: $SOURCE_DIR"
echo "  Output: $PACKAGE_PATH"

# Switched from tar.xz to zip so 7zip 9.20 on Win98 SE can extract in one
# pass without spilling a ~700 MB scratch tar. zip also has no hardlink
# concept, so the FAT32-incompatible hardlinks (g++.exe → c++.exe,
# ld.exe → ld.bfd.exe, etc.) become independent full-content entries
# automatically — no --hard-dereference equivalent needed.
#
# `cp -al` stages an instant hardlink-copy of the install tree under the
# renamed top-level so zip writes "gcc_win98/..." instead of
# "native-toolset/...". Hardlinks within the stage cost no disk; zip
# dereferences them at archive time.
#
# The stage MUST live on the same filesystem as $SOURCE_DIR — `cp -al`
# fails with EXDEV across devices. In the toolchain-builder container,
# /work is a bind-mount and /tmp is the overlay FS, so mktemp's default
# /tmp would break the hardlink call.
STAGE=$(mktemp -d -p "$PACKAGE_DIR" gcc-win98-native-zip.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM
cp -al "$SOURCE_DIR" "$STAGE/gcc_win98"
( cd "$STAGE" && zip -9 -q -r "$PACKAGE_PATH" gcc_win98 )

echo ""
echo "Package created successfully!"
echo ""
stat --printf='Path: %n\nSize: %s bytes\n' "$PACKAGE_PATH"
sha256sum "$PACKAGE_PATH"
mark_done package-native-toolset
