#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# common.sh - Shared utilities for gcc-for-Windows98 build scripts
# ============================================================================
# Usage: source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
# ============================================================================

# Git Bash on Windows (MSYS / Git for Windows) translates Unix-style absolute
# paths in command arguments to Windows paths (e.g. /work/scripts/foo.sh
# becomes C:/git-sdk-64/work/scripts/foo.sh) before `docker compose exec`
# passes them to the container. We can't blanket-disable conversion because
# the host docker-compose.yml path still needs Windows translation for
# docker.exe to find it. Instead, individual builder_*/consumer_* helpers
# below prepend an extra slash to in-container paths (//work/... — MSYS
# skips conversion on double-slash paths, and the in-container bash
# collapses them to /work/... per POSIX).
in_container_path() {
  # Echo a path that survives MSYS arg conversion intact when passed as a
  # standalone arg to docker compose exec. On Linux this is a no-op; on
  # Git Bash, the extra leading slash bypasses the rootfs-prefix mapping
  # that would otherwise rewrite /work/... to C:/git-sdk-XX/work/....
  if [[ -n "${MSYSTEM:-}" ]]; then
    echo "/$1"
  else
    echo "$1"
  fi
}

# --- Directory Layout -------------------------------------------------------
COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${COMMON_LIB_DIR}/../.." && pwd)"
# Scripts are entered as `bash //work/scripts/...` on Git Bash (the `//` is the
# MSYS-conversion guard from in_container_path). POSIX leaves leading `//`
# implementation-defined; bash preserves it through cd...pwd, and wine then
# treats `//work/...` as a Windows UNC path and fails to find the file. Collapse
# any leading double-slash so every path derived from ROOT_DIR is wine-safe.
while [[ "$ROOT_DIR" == //* ]]; do
  ROOT_DIR="${ROOT_DIR#/}"
done
while [[ "$COMMON_LIB_DIR" == //* ]]; do
  COMMON_LIB_DIR="${COMMON_LIB_DIR#/}"
done
SRC_DIR="$ROOT_DIR/src"
BUILD_DIR="$ROOT_DIR/build"
LOG_DIR="$ROOT_DIR/logs"
OUT_DIR="$ROOT_DIR/out"
PATCH_DIR="$ROOT_DIR/patches"

# --- Build Configuration ----------------------------------------------------
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
TARGET="${TARGET:-i686-w64-mingw32}"
PREFIX="${PREFIX:-$OUT_DIR/toolchain}"
MATRIX="${MATRIX:-0}"

# --- Win98-host binary flags ------------------------------------------------
# Reference (don't auto-inherit) from build-native-*.sh that produces a
# Win98-hosted binary. CPPFLAGS gate mingw-w64 header feature detection so
# configure scripts don't autodetect Vista+ APIs (GetFileInformationByHandleEx,
# GetFinalPathNameByHandleA, FindFirstVolumeW, ...) that would later fail to
# resolve on Win98's PE loader. LDFLAGS strip the DllCharacteristics bits the
# Win98 loader doesn't recognize (DYNAMIC_BASE / NX_COMPAT — advisory on NT
# but suspicious on 9x) and pin MajorSubsystemVersion ≤ 4 against any future
# binutils default bump.
WIN98_TARGET_CPPFLAGS="-D_WIN32_WINNT=0x0400 -DWINVER=0x0400"
WIN98_TARGET_LDFLAGS="-Wl,--disable-dynamicbase -Wl,--disable-nxcompat -Wl,--major-subsystem-version=4"

# --- Win98 compatibility shim flags -----------------------------------------
# The shim works by IAT interception: libwin98compat.a defines __imp__FOO@N
# slots for the shimmed APIs (GetFinalPathNameByHandleA, getaddrinfo,
# qsort_s, ...) pre-pointing at win98_FOO wrappers. With -lwin98compat in
# the link line ahead of the implicit -lkernel32 / -lws2_32 / -ladvapi32 /
# -lmsvcrt, the linker resolves the consumer's `call *_imp__FOO@N` against
# us — no import descriptor for FOO from the real DLL is emitted, and the
# wrapper handles the call (real API via GetProcAddress on NT hosts,
# behavior-preserving fallback on Win9x).
#
# CPPFLAGS is intentionally empty: no -include header force-load (the
# previous design did this and ran into windows.h vs binutils-BFD/libiberty
# namespace collisions). Consumers only need to LINK the library.
#
# --whole-archive is load-bearing here: autotools puts user LDFLAGS BEFORE
# the object files on the link line, so a plain `-lwin98compat` is scanned
# while no symbol is undefined yet — GNU ld pulls nothing from the archive
# and moves on. By the time the consumer's .o files introduce references
# to _imp__getaddrinfo@16 / _imp__freeaddrinfo@4 / ..., the later
# -lws2_32 / -lkernel32 short import libraries resolve them first and emit
# import descriptors pointing at the real (Win98-missing) DLL exports.
# --whole-archive forces every member of libwin98compat.a into the link
# at the point of -lwin98compat, defining all __imp__* slots up front so
# the system import libraries never get a chance.
#
# The library lives in the cross-toolchain sysroot
# (out/toolchain/i686-w64-mingw32/lib) so the cross gcc finds it on its
# default -L search paths. win98_compat.h still installs into the sysroot
# include dir for downstream code that wants to call win98_* wrappers
# explicitly; it's just no longer force-included.
#
# Inherit alongside WIN98_TARGET_* from any build-native-*.sh whose binary
# is destined for Win98.
WIN98_COMPAT_CPPFLAGS=""
WIN98_COMPAT_LDFLAGS="-Wl,--whole-archive -lwin98compat -Wl,--no-whole-archive"

# Status sentinel scope prevents false resume/skip across different build
# configurations (e.g., matrix/target changes).
STATUS_SCOPE="${STATUS_SCOPE:-${TARGET}__m${MATRIX}}"

# --- Dependency Version Configuration (populated from config.json) ---------
GMP_VERSION=""
MPFR_VERSION=""
MPC_VERSION=""

# --- Source Fetch Configuration (populated from config.json) ----------------
# These are intentionally empty here; load_fetch_config_from_json fills them
# in from config.json, which is the single source of truth for component
# sources and revisions.
GCC_FETCH_SOURCE=""
GCC_FETCH_REF=""

BINUTILS_FETCH_SOURCE=""
BINUTILS_FETCH_REF=""

MINGW_W64_FETCH_SOURCE=""
MINGW_W64_FETCH_REF=""

PTHREAD9X_FETCH_SOURCE=""
PTHREAD9X_FETCH_REF=""

BUSYBOX_W32_FETCH_SOURCE=""
BUSYBOX_W32_FETCH_REF=""

MAKE_FETCH_SOURCE=""
MAKE_FETCH_REF=""

CTAGS_FETCH_SOURCE=""
CTAGS_FETCH_REF=""

DIFFUTILS_FETCH_SOURCE=""
DIFFUTILS_FETCH_REF=""

PATCH_FETCH_SOURCE=""
PATCH_FETCH_REF=""

MUON_FETCH_SOURCE=""
MUON_FETCH_REF=""

# Optional tarball overrides per component (empty if not configured).
# When *_TARBALL_URL is set, fetch-sources.sh prefers it over a git clone.
GCC_TARBALL_URL=""
GCC_TARBALL_SHA512=""
GCC_TARBALL_SHA256=""
GCC_TARBALL_STRIP=""

BINUTILS_TARBALL_URL=""
BINUTILS_TARBALL_SHA512=""
BINUTILS_TARBALL_SHA256=""
BINUTILS_TARBALL_STRIP=""

MINGW_W64_TARBALL_URL=""
MINGW_W64_TARBALL_SHA512=""
MINGW_W64_TARBALL_SHA256=""
MINGW_W64_TARBALL_STRIP=""

PTHREAD9X_TARBALL_URL=""
PTHREAD9X_TARBALL_SHA512=""
PTHREAD9X_TARBALL_SHA256=""
PTHREAD9X_TARBALL_STRIP=""

BUSYBOX_W32_TARBALL_URL=""
BUSYBOX_W32_TARBALL_SHA512=""
BUSYBOX_W32_TARBALL_SHA256=""
BUSYBOX_W32_TARBALL_STRIP=""

MAKE_TARBALL_URL=""
MAKE_TARBALL_SHA512=""
MAKE_TARBALL_SHA256=""
MAKE_TARBALL_STRIP=""

CTAGS_TARBALL_URL=""
CTAGS_TARBALL_SHA512=""
CTAGS_TARBALL_SHA256=""
CTAGS_TARBALL_STRIP=""

DIFFUTILS_TARBALL_URL=""
DIFFUTILS_TARBALL_SHA512=""
DIFFUTILS_TARBALL_SHA256=""
DIFFUTILS_TARBALL_STRIP=""

PATCH_TARBALL_URL=""
PATCH_TARBALL_SHA512=""
PATCH_TARBALL_SHA256=""
PATCH_TARBALL_STRIP=""

MUON_TARBALL_URL=""
MUON_TARBALL_SHA512=""
MUON_TARBALL_SHA256=""
MUON_TARBALL_STRIP=""

# Component release/version values from config.json matrix (distinct from fetch refs).
GCC_COMPONENT_VERSION=""
BINUTILS_COMPONENT_VERSION=""
MINGW_W64_COMPONENT_VERSION=""
PTHREAD9X_COMPONENT_VERSION=""
BUSYBOX_W32_COMPONENT_VERSION=""
MAKE_COMPONENT_VERSION=""
CTAGS_COMPONENT_VERSION=""
DIFFUTILS_COMPONENT_VERSION=""
PATCH_COMPONENT_VERSION=""
MUON_COMPONENT_VERSION=""
MATRIX_SELECTED_LABEL=""

load_fetch_config_from_json() {
  local config_file="$ROOT_DIR/config.json"
  [[ -f "$config_file" ]] || return 0
  command -v python3 >/dev/null 2>&1 || {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "WARN: python3 not found; using built-in fetch defaults" >&2
  return 0
  }

  local parser_script="$COMMON_LIB_DIR/config_matrix_exports.py"
  [[ -f "$parser_script" ]] || {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "WARN: parser not found: $parser_script; using built-in fetch defaults" >&2
  return 0
  }

  local parsed
  parsed="$({
  python3 "$parser_script" "$config_file" "$MATRIX"
  } 2>/dev/null || true)"

  if [[ -n "$parsed" ]]; then
  eval "$parsed"
  fi
}

load_fetch_config_from_json

# --- Ensure directories exist -----------------------------------------------
mkdir -p "$SRC_DIR" "$BUILD_DIR" "$LOG_DIR" "$OUT_DIR"

# --- Logging ----------------------------------------------------------------
log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "FATAL: $*" >&2
  exit 1
}

warn() {
  log "WARN: $*" >&2
}

# --- Command Execution with Logging -----------------------------------------
run_logged() {
  local log_name="$1"
  shift
  log "running: $*"
  "$@" 2>&1 | tee -a "$LOG_DIR/$log_name"
}

# --- Step / Resume Support --------------------------------------------------
# Usage:
#   require_step <name> <message>     # exits if previous step not done
#   skip_if_done <name> <message>     # exits 0 if this step already done
#   mark_step_done <name>             # mark current step complete
#
# Steps are tracked via $OUT_DIR/.status-<name> sentinel files.

status_file() {
  echo "$OUT_DIR/.status-${STATUS_SCOPE}-$1"
}

status_file_in_builder() {
  echo "/work/out/.status-${STATUS_SCOPE}-$1"
}

mark_done() {
  touch "$(status_file "$1")"
}

is_done() {
  [[ -f "$(status_file "$1")" ]]
}

require_step() {
  local step_name="$1"
  local message="${2:-run $step_name first}"
  if ! is_done "$step_name"; then
    die "$message"
  fi
}

skip_if_done() {
  local step_name="$1"
  local message="${2:-$step_name already done, skipping}"
  if is_done "$step_name"; then
    log "$message"
    exit 0
  fi
}

# --- Directory Guards -------------------------------------------------------
require_dir() {
  local dir="$1"
  local message="${2:-missing directory: $dir}"
  [[ -d "$dir" ]] || die "$message"
}

require_file() {
  local file="$1"
  local message="${2:-missing file: $file}"
  [[ -f "$file" ]] || die "$message"
}

require_executable() {
  local cmd="$1"
  local message="${2:-missing executable: $cmd}"
  command -v "$cmd" >/dev/null 2>&1 || die "$message"
}

# --- Git Helpers ------------------------------------------------------------
ensure_shallow_git_checkout() {
  local repo="$1"
  local ref="$2"
  local dest="$3"

  # If dest already has a valid git repo, try to reuse it (avoid re-clone on retry)
  if [[ -d "$dest/.git" ]]; then
    log "existing clone at $dest, reusing..."
    git -C "$dest" remote set-url origin "$repo" 2>/dev/null || true
    if git -C "$dest" fetch --depth 1 origin "$ref" 2>/dev/null; then
      git -C "$dest" checkout --detach FETCH_HEAD 2>/dev/null && return
    fi
    log "reuse failed, re-cloning..."
    rm -rf "$dest"
  fi

  # If ref looks like a commit SHA, clone and then checkout that exact commit.
  if [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    git clone --depth 1 "$repo" "$dest"
    git -C "$dest" fetch --depth 1 origin "$ref"
    git -C "$dest" checkout --detach FETCH_HEAD
    return
  fi

  # Try branch first (ref could be a branch or a tag)
  if git clone --depth 1 --branch "$ref" "$repo" "$dest" 2>/dev/null; then
    return
  fi

  # Fallback: ref is likely a tag — clone default branch, then fetch the tag
  log "clone --branch failed for $ref, trying tag fetch..."
  rm -rf "$dest"
  git clone --depth 1 "$repo" "$dest"
  # Fetch dereferenced tag to get commit objects (not just annotated tag object)
  git -C "$dest" fetch --depth 1 origin "refs/tags/$ref:refs/tags/$ref" 2>/dev/null || \
    git -C "$dest" fetch --depth 1 origin "refs/tags/$ref"
  git -C "$dest" checkout --detach FETCH_HEAD
}

# --- Tarball Helpers --------------------------------------------------------
# Download a release tarball, verify its checksum, and extract it to a
# destination directory. Faster than git clone for large repos because there
# is no per-file checkout phase — tar extracts as one streaming write.
#
# Args:
#   $1  url           tarball URL (https; any tar-recognized compression)
#   $2  checksum_alg  "sha512", "sha256", or "" to skip verification
#   $3  checksum      expected digest in lowercase hex (or "" if alg is "")
#   $4  dest          destination directory (created or repopulated)
#   $5  strip         --strip-components value (defaults to 1)
#
# Successful extraction writes a sentinel file at $dest/.tarball-extracted so
# re-runs skip the download. Remove the sentinel (or the whole $dest) to
# force a fresh fetch.
download_and_extract_tarball() {
  local url="$1"
  local checksum_alg="$2"
  local checksum="$3"
  local dest="$4"
  local strip="${5:-1}"
  local marker="$dest/.tarball-extracted"

  if [[ -f "$marker" ]]; then
    log "tarball already extracted at $dest (marker present)"
    return 0
  fi

  log "downloading tarball: $url"
  rm -rf "$dest"
  mkdir -p "$dest"

  local tmp
  tmp=$(mktemp)
  if ! curl -fLo "$tmp" "$url"; then
    rm -f "$tmp"
    die "tarball download failed: $url"
  fi

  if [[ -n "$checksum_alg" && -n "$checksum" ]]; then
    local actual
    case "$checksum_alg" in
      sha512) actual=$(sha512sum "$tmp" | awk '{print $1}') ;;
      sha256) actual=$(sha256sum "$tmp" | awk '{print $1}') ;;
      *)
        rm -f "$tmp"
        die "unknown checksum algorithm: $checksum_alg"
        ;;
    esac
    if [[ "$actual" != "$checksum" ]]; then
      rm -f "$tmp"
      die "$checksum_alg mismatch for $url: expected $checksum, got $actual"
    fi
    log "$checksum_alg verified: $actual"
  else
    warn "no checksum configured for $url — relying on TLS only"
  fi

  log "extracting to $dest (--strip-components=$strip)"
  if ! tar -xf "$tmp" -C "$dest" --strip-components="$strip"; then
    rm -f "$tmp"
    die "tarball extraction failed for $url"
  fi
  rm -f "$tmp"

  touch "$marker"
  log "tarball extraction complete: $dest"
}

# Dispatcher: prefer tarball if URL is set, otherwise shallow git clone.
# All "$component_*" args are positional so callers can pass the relevant
# *_TARBALL_*/*_FETCH_* variables in directly.
#
# Args:
#   $1  name           component name (used for log and dest dir)
#   $2  fetch_source   git URL (used when tarball URL is empty)
#   $3  fetch_ref      git tag/branch/SHA (used when tarball URL is empty)
#   $4  tarball_url    optional tarball URL
#   $5  tarball_sha512 optional sha512
#   $6  tarball_sha256 optional sha256
#   $7  tarball_strip  optional --strip-components value (default 1)
fetch_component() {
  local name="$1"
  local fetch_source="$2"
  local fetch_ref="$3"
  local tarball_url="$4"
  local tarball_sha512="$5"
  local tarball_sha256="$6"
  local tarball_strip="${7:-1}"
  local dest="$SRC_DIR/$name"

  if [[ -n "$tarball_url" ]]; then
    log "$name: tarball=$tarball_url"
    local alg="" sum=""
    if [[ -n "$tarball_sha512" ]]; then
      alg="sha512"; sum="$tarball_sha512"
    elif [[ -n "$tarball_sha256" ]]; then
      alg="sha256"; sum="$tarball_sha256"
    fi
    download_and_extract_tarball "$tarball_url" "$alg" "$sum" "$dest" "$tarball_strip"
  else
    log "$name: source=$fetch_source ref=$fetch_ref"
    ensure_shallow_git_checkout "$fetch_source" "$fetch_ref" "$dest"
    verify_checkout_ref "$dest" "$fetch_ref" "$name"
  fi
}

patch_url_for_commit() {
  local repo="$1"
  local sha="$2"
  repo="${repo%.git}"
  printf '%s/commit/%s.patch\n' "$repo" "$sha"
}

apply_remote_commit_patch() {
  local repo="$1"
  local sha="$2"
  local dest="$3"
  local patch_file
  patch_file="$(mktemp)"
  curl -L "$(patch_url_for_commit "$repo" "$sha")" -o "$patch_file"
  git -C "$dest" apply "$patch_file"
  rm -f "$patch_file"
}

revert_remote_commit_patch() {
  local repo="$1"
  local sha="$2"
  local dest="$3"
  local patch_file
  patch_file="$(mktemp)"
  curl -L "$(patch_url_for_commit "$repo" "$sha")" -o "$patch_file"
  git -C "$dest" apply -R "$patch_file"
  rm -f "$patch_file"
}

# --- Header -----------------------------------------------------------------
log "common.sh loaded — ROOT_DIR=$ROOT_DIR, JOBS=$JOBS, TARGET=$TARGET"

# --- Docker Compose Helpers -------------------------------------------------
# These require PROJECT_DIR (the repro/ folder) to be set so that
# docker compose can locate the docker-compose.yml file.
PROJECT_DIR="${PROJECT_DIR:-$(cd "${COMMON_LIB_DIR}/../.." && pwd)}"

# Run a command inside the toolchain-builder container.
builder_exec() {
  docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T toolchain-builder bash -c "$*"
}

# Run a named script inside the toolchain-builder container.
builder_script() {
  local script_rel="$1"
  shift
  local full_path
  full_path="$(in_container_path "/work/scripts/$script_rel")"
  docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T toolchain-builder \
    env JOBS="$JOBS" TARGET="$TARGET" MATRIX="$MATRIX" GENERATE_PATCHES="${GENERATE_PATCHES:-0}" \
    bash "$full_path" "$@"
}

# Create a status file inside the toolchain-builder container (shared /work/out volume).
mark_done_in_builder() {
  local status_name="$1"
  builder_exec "touch $(status_file_in_builder "$status_name")"
}

# Check if a status file exists inside the toolchain-builder container.
is_done_in_builder() {
  local status_name="$1"
  builder_exec "test -f $(status_file_in_builder "$status_name")" 2>/dev/null && return 0 || return 1
}

# Run a command inside the consumer container.
consumer_exec() {
  docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T consumer bash -c "$*"
}

# Run a named script inside the consumer container.
consumer_script() {
  local script_rel="$1"
  shift
  local full_path
  full_path="$(in_container_path "/workspace/scripts/$script_rel")"
  docker compose -f "$PROJECT_DIR/docker-compose.yml" exec -T consumer bash "$full_path" "$@"
}
