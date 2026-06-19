#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# fetch-sources.sh - Fetch source trees for gcc-for-Windows98
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

require_file "$ROOT_DIR/config.json" "missing config.json; expected at $ROOT_DIR/config.json"

verify_checkout_ref() {
	local repo_dir="$1"
	local expected_ref="$2"
	local label="$3"
	local head
	head="$(git -C "$repo_dir" rev-parse HEAD)"

	if [[ "$expected_ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
		if [[ "$head" != "$expected_ref"* ]]; then
			die "$label revision mismatch: expected commit prefix $expected_ref, got $head"
		fi
	else
		local resolved
		# Dereference annotated tags to get the commit, not the tag object
		resolved="$(git -C "$repo_dir" rev-parse "$expected_ref^{commit}" 2>/dev/null || git -C "$repo_dir" rev-parse "$expected_ref")"
		if [[ "$head" != "$resolved" ]]; then
			die "$label revision mismatch: expected $expected_ref -> $resolved, got $head"
		fi
	fi

	log "$label verified at $head"
}

log "fetching source trees"

fetch_component "gcc" \
  "$GCC_FETCH_SOURCE" "$GCC_FETCH_REF" \
  "$GCC_TARBALL_URL" "$GCC_TARBALL_SHA512" "$GCC_TARBALL_SHA256" "${GCC_TARBALL_STRIP:-1}"

fetch_component "binutils-gdb" \
  "$BINUTILS_FETCH_SOURCE" "$BINUTILS_FETCH_REF" \
  "$BINUTILS_TARBALL_URL" "$BINUTILS_TARBALL_SHA512" "$BINUTILS_TARBALL_SHA256" "${BINUTILS_TARBALL_STRIP:-1}"

fetch_component "mingw-w64" \
  "$MINGW_W64_FETCH_SOURCE" "$MINGW_W64_FETCH_REF" \
  "$MINGW_W64_TARBALL_URL" "$MINGW_W64_TARBALL_SHA512" "$MINGW_W64_TARBALL_SHA256" "${MINGW_W64_TARBALL_STRIP:-1}"

fetch_component "pthread9x" \
  "$PTHREAD9X_FETCH_SOURCE" "$PTHREAD9X_FETCH_REF" \
  "$PTHREAD9X_TARBALL_URL" "$PTHREAD9X_TARBALL_SHA512" "$PTHREAD9X_TARBALL_SHA256" "${PTHREAD9X_TARBALL_STRIP:-1}"

fetch_component "busybox-w32" \
  "$BUSYBOX_W32_FETCH_SOURCE" "$BUSYBOX_W32_FETCH_REF" \
  "$BUSYBOX_W32_TARBALL_URL" "$BUSYBOX_W32_TARBALL_SHA512" "$BUSYBOX_W32_TARBALL_SHA256" "${BUSYBOX_W32_TARBALL_STRIP:-1}"

fetch_component "make" \
  "$MAKE_FETCH_SOURCE" "$MAKE_FETCH_REF" \
  "$MAKE_TARBALL_URL" "$MAKE_TARBALL_SHA512" "$MAKE_TARBALL_SHA256" "${MAKE_TARBALL_STRIP:-1}"

fetch_component "ctags" \
  "$CTAGS_FETCH_SOURCE" "$CTAGS_FETCH_REF" \
  "$CTAGS_TARBALL_URL" "$CTAGS_TARBALL_SHA512" "$CTAGS_TARBALL_SHA256" "${CTAGS_TARBALL_STRIP:-1}"

fetch_component "diffutils" \
  "$DIFFUTILS_FETCH_SOURCE" "$DIFFUTILS_FETCH_REF" \
  "$DIFFUTILS_TARBALL_URL" "$DIFFUTILS_TARBALL_SHA512" "$DIFFUTILS_TARBALL_SHA256" "${DIFFUTILS_TARBALL_STRIP:-1}"

fetch_component "patch" \
  "$PATCH_FETCH_SOURCE" "$PATCH_FETCH_REF" \
  "$PATCH_TARBALL_URL" "$PATCH_TARBALL_SHA512" "$PATCH_TARBALL_SHA256" "${PATCH_TARBALL_STRIP:-1}"

fetch_component "muon" \
  "$MUON_FETCH_SOURCE" "$MUON_FETCH_REF" \
  "$MUON_TARBALL_URL" "$MUON_TARBALL_SHA512" "$MUON_TARBALL_SHA256" "${MUON_TARBALL_STRIP:-1}"

log "using container-provided dev packages for gmp/mpfr/mpc in the first reproduction pass"
mark_done fetch-sources
log "fetch complete"
