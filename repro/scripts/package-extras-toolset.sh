#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# package-extras-toolset.sh - Package the extras toolset
# ============================================================================
# Bundles out/extras-toolset/ (busybox, make, ctags, diffutils, patch, gdb,
# muon) into out/package/gcc-win98-native-toolchain-extras.zip. The archive's top-level
# directory is renamed to gcc_win98_extras/ to keep it visually distinct
# from the cross-toolchain archive (which uses gcc_win98/).
#
# Zip (not tar.xz) so 7zip 9.20 on Win98 SE can extract in one pass without
# a ~300 MB scratch tar.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_step verify-extras-package "run verifiers/verify-extras-package.sh first"

REPO_ROOT="$ROOT_DIR"
SOURCE_DIR="$REPO_ROOT/out/extras-toolset"
PACKAGE_DIR="$REPO_ROOT/out/package"
PACKAGE_NAME="gcc-win98-native-toolchain-extras.zip"
PACKAGE_PATH="$PACKAGE_DIR/$PACKAGE_NAME"

require_dir "$SOURCE_DIR/bin" "Extras toolset not found at $SOURCE_DIR (run extras build steps first)"

mkdir -p "$PACKAGE_DIR"
rm -f "$PACKAGE_PATH"

echo "Packaging extras toolset..."
echo "  Source: $SOURCE_DIR"
echo "  Output: $PACKAGE_PATH"

# Stage via `cp -al` so zip writes "gcc_win98_extras/..." instead of
# "extras-toolset/...". zip has no hardlink concept and dereferences each
# entry independently — busybox's sh.exe-as-copy and any future hardlinks
# all materialize as full content automatically.
#
# Stage MUST live on the same filesystem as $SOURCE_DIR — `cp -al` fails
# with EXDEV across devices. In the toolchain-builder container, /work is
# a bind-mount and /tmp is the overlay FS, so default-mktemp /tmp breaks
# the hardlink call.
STAGE=$(mktemp -d -p "$PACKAGE_DIR" gcc-win98-native-toolchain-extras-zip.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT INT TERM
cp -al "$SOURCE_DIR" "$STAGE/gcc_win98_extras"
( cd "$STAGE" && zip -9 -q -r "$PACKAGE_PATH" gcc_win98_extras )

echo ""
echo "Package created successfully!"
echo ""
stat --printf='Path: %n\nSize: %s bytes\n' "$PACKAGE_PATH"
sha256sum "$PACKAGE_PATH"

mark_done package-extras-toolset
