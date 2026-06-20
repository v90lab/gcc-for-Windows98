#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
source "$SCRIPT_DIR/../lib/status-common.sh"

status_section "native status markers"
status_step_line "build-native-mingw-deps"
status_step_line "build-native-host-gcc"
status_step_line "build-native-binutils"
status_step_line "build-native-mingw-w64"
status_step_line "build-native-pthread9x"
status_step_line "verify-native-compiler-features"
status_step_line "package-native-toolset"
status_step_line "write-native-toolchain-manifest-v2"

status_section "native artifacts"
NATIVE_PKG="$OUT_DIR/package/gcc-win98-native-toolchain.zip"
NATIVE_MANIFEST="$OUT_DIR/package/gcc-win98-native-toolchain.json"
NATIVE_FEATURES="$OUT_DIR/compiler-features/native.json"
status_file_meta "$NATIVE_PKG"
status_sha256_if_file "$NATIVE_PKG"
status_exists_line "$NATIVE_MANIFEST"
status_exists_line "$NATIVE_FEATURES"
status_exists_line "$OUT_DIR/mingw-deps/lib/libgmp.a"
status_exists_line "$OUT_DIR/mingw-deps/lib/libmpfr.a"
status_exists_line "$OUT_DIR/mingw-deps/lib/libmpc.a"

status_section "native toolset layout"
status_exists_line "$OUT_DIR/native-toolset/bin/gcc.exe"
status_exists_line "$OUT_DIR/native-toolset/bin/g++.exe"
status_exists_line "$OUT_DIR/native-toolset/bin/ar.exe"
status_exists_line "$OUT_DIR/native-toolset/bin/ld.exe"
status_exists_line "$OUT_DIR/native-toolset/$TARGET/include/stdio.h"
status_exists_line "$OUT_DIR/native-toolset/$TARGET/lib/libpthread.a"

status_section "native package verifier"
if [[ -x "$SCRIPT_DIR/../verifiers/verify-native-package.sh" ]]; then
	if "$SCRIPT_DIR/../verifiers/verify-native-package.sh"; then
		status_say "native_package_verification=pass"
	else
		status_say "native_package_verification=fail"
	fi
else
	status_say "native_package_verification=missing-check"
fi

status_section "native logs"
status_tail_latest "$LOG_DIR" "run-toolchain-build-*.log" 25

