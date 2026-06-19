#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

PACKAGE_DIR="$OUT_DIR/package"
COMPILER_FEATURES_DIR="$OUT_DIR/compiler-features"
MANIFEST_SCRIPT="$ROOT_DIR/scripts/lib/toolchain_manifest.py"
GCC_VERSION="${GCC_COMPONENT_VERSION:?missing GCC_COMPONENT_VERSION from config.json}"

write_manifest() {
  local artifact_filename="$1"
  local manifest_filename="$2"
  local package_kind="$3"
  local status_name="$4"
  local compiler_features_path="$5"
  local artifact_path="$PACKAGE_DIR/$artifact_filename"
  local manifest_path="$PACKAGE_DIR/$manifest_filename"
  local sha256

  if [[ ! -f "$artifact_path" ]]; then
    return 0
  fi

  require_file "$compiler_features_path" "missing compiler feature results: $compiler_features_path"

  sha256=$(sha256sum "$artifact_path" | awk '{print $1}')

  python3 "$MANIFEST_SCRIPT" \
    --artifact-path "$artifact_path" \
    --artifact-filename "$artifact_filename" \
    --sha256 "$sha256" \
    --gcc-version "$GCC_VERSION" \
    --target "$TARGET" \
    --package-kind "$package_kind" \
    --compiler-features-path "$compiler_features_path" \
    --output "$manifest_path"

  mark_done "$status_name"
}

write_manifest \
  "gcc-win98-toolchain.tar.xz" \
  "gcc-win98-toolchain.json" \
  "cross-toolchain" \
  "write-toolchain-manifest-v2" \
  "$COMPILER_FEATURES_DIR/cross.json"

write_manifest \
  "gcc-win98-native-toolset.zip" \
  "gcc-win98-native-toolset.json" \
  "native-toolset" \
  "write-native-toolchain-manifest-v2" \
  "$COMPILER_FEATURES_DIR/native.json"

write_extras_manifest() {
  local artifact_path="$PACKAGE_DIR/gcc-win98-extras.zip"
  local manifest_path="$PACKAGE_DIR/gcc-win98-extras.json"

  if [[ ! -f "$artifact_path" ]]; then
    return 0
  fi

  local sha256 size
  sha256=$(sha256sum "$artifact_path" | awk '{print $1}')
  size=$(stat -c%s "$artifact_path")

  python3 - "$artifact_path" "$manifest_path" "$sha256" "$size" "$TARGET" \
      "${BUSYBOX_W32_COMPONENT_VERSION:-unknown}" \
      "${MAKE_COMPONENT_VERSION:-unknown}" \
      "${CTAGS_COMPONENT_VERSION:-unknown}" \
      "${DIFFUTILS_COMPONENT_VERSION:-unknown}" \
      "${PATCH_COMPONENT_VERSION:-unknown}" \
      "${MUON_COMPONENT_VERSION:-unknown}" \
      "${BINUTILS_COMPONENT_VERSION:-unknown}" <<'PY'
import json
import sys
from pathlib import Path

(_script, _artifact_path, manifest_path, sha256, size, target,
 busybox_v, make_v, ctags_v, diffutils_v, patch_v, muon_v, binutils_v) = sys.argv

manifest = {
    "artifact": {
        "filename": "gcc-win98-extras.zip",
        "sha256": sha256,
        "size": int(size),
    },
    "toolchain": {
        "target": target,
        "package_kind": "extras-toolset",
        "crt": "msvcrt",
    },
    "tools": {
        "busybox-w32": {"version": busybox_v},
        "make":        {"version": make_v},
        "ctags":       {"version": ctags_v},
        "diffutils":   {"version": diffutils_v},
        "patch":       {"version": patch_v},
        "muon":        {"version": muon_v},
        "gdb":         {"version": f"from binutils {binutils_v}"},
    },
    "metadata": {
        "project": "gcc-for-Windows98",
        "homepage": "https://github.com/longhronshen/gcc-for-Windows98",
    },
}

out = Path(manifest_path)
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
print(f"Manifest written to {out}")
PY

  mark_done write-extras-toolchain-manifest-v2
}

write_extras_manifest

if [[ ! -f "$PACKAGE_DIR/gcc-win98-toolchain.tar.xz" && ! -f "$PACKAGE_DIR/gcc-win98-native-toolset.zip" ]]; then
  echo "Error: No packaged toolchain artifacts found in $PACKAGE_DIR"
  exit 1
fi
