#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/status-common.sh"

status_section "extras status markers"
status_step_line "build-native-busybox"
status_step_line "build-native-make"
status_step_line "build-native-ctags"
status_step_line "build-native-diffutils"
status_step_line "build-native-patch"
status_step_line "build-native-gdb"
status_step_line "build-native-muon"
status_step_line "verify-extras-package"
status_step_line "package-extras-toolset"
status_step_line "write-extras-toolchain-manifest-v2"

status_section "extras artifacts"
EXTRAS_PKG="$OUT_DIR/package/gcc-win98-native-toolchain-extras.zip"
EXTRAS_MANIFEST="$OUT_DIR/package/gcc-win98-native-toolchain-extras.json"
status_file_meta "$EXTRAS_PKG"
status_sha256_if_file "$EXTRAS_PKG"
status_exists_line "$EXTRAS_MANIFEST"

status_section "extras toolset layout"
status_exists_line "$OUT_DIR/extras-toolset/bin/busybox.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/sh.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/make.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/ctags.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/diff.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/cmp.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/patch.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/gdb.exe"
status_exists_line "$OUT_DIR/extras-toolset/bin/muon.exe"

status_section "extras package verifier"
if [[ -x "$SCRIPT_DIR/../verifiers/verify-extras-package.sh" ]]; then
	if "$SCRIPT_DIR/../verifiers/verify-extras-package.sh"; then
		status_say "extras_package_verification=pass"
	else
		status_say "extras_package_verification=fail"
	fi
else
	status_say "extras_package_verification=missing-check"
fi
