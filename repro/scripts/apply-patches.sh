#!/usr/bin/env bash
# apply-patches.sh - Apply Win98 compatibility patches
# Usage:
#   scripts/apply-patches.sh [component] [version]
#   scripts/apply-patches.sh gcc 11.1.0
#   scripts/apply-patches.sh mingw-w64 master
#   scripts/apply-patches.sh all
#
# Reads patch lists from patches/{component}/{version}/series.txt,
# applies them in order using git apply / patch -p1, and stops on failure.

set -euo pipefail

# Resolve script paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPRO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PATCHES_DIR="${REPRO_DIR}/patches"
SRC_DIR="${REPRO_DIR}/src"
LOG_FILE="${REPRO_DIR}/logs/apply-patches.log"

# Load matrix-resolved component versions and fetch refs.
source "${SCRIPT_DIR}/lib/common.sh"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Logging helper
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Apply a single patch file
apply_patch() {
    local patch_file="$1"
    local source_dir="$2"
    local patch_name
    patch_name="$(basename "$patch_file")"

    log "Applying: $patch_name"

    # Prefer git apply first
    if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
        git -C "$source_dir" apply "$patch_file"
        log "  ✓ Applied via git apply: $patch_name"
        return 0
    fi

    # Fallback to patch -p1 (use -N to skip already-applied patches)
    if patch -d "$source_dir" -p1 -N --dry-run -i "$patch_file" 2>/dev/null; then
        patch -d "$source_dir" -p1 -N -i "$patch_file" 2>/dev/null
        log "  ✓ Applied via patch -p1: $patch_name"
        return 0
    fi

    # If patch was already applied, that's OK — treat as success
    if patch -d "$source_dir" -p1 -R --dry-run -i "$patch_file" 2>/dev/null; then
        log "  ✓ Already applied (skipped): $patch_name"
        return 0
    fi

    log "  ✗ FAILED to apply: $patch_name"
    return 1
}

# Apply all patches for one component
apply_component() {
    local component="$1"
    local version="${2:-}"
    local component_patches_dir
    local source_dir

    # Resolve source directory for the component
    case "$component" in
        gcc)
            source_dir="${SRC_DIR}/gcc"
            ;;
        mingw-w64)
            source_dir="${SRC_DIR}/mingw-w64"
            ;;
        binutils-gdb)
            source_dir="${SRC_DIR}/binutils-gdb"
            ;;
        pthread9x)
            source_dir="${SRC_DIR}/pthread9x"
            ;;
        busybox-w32)
            source_dir="${SRC_DIR}/busybox-w32"
            ;;
        make)
            source_dir="${SRC_DIR}/make"
            ;;
        *)
            log "ERROR: Unknown component: $component"
            return 1
            ;;
    esac

    if [[ -n "$version" && -d "${PATCHES_DIR}/${component}/${version}" ]]; then
        component_patches_dir="${PATCHES_DIR}/${component}/${version}"
    elif [[ -d "${PATCHES_DIR}/${component}" ]]; then
        component_patches_dir="${PATCHES_DIR}/${component}"
    else
        log "ERROR: Patch directory not found for component=${component}, version=${version:-<none>}"
        return 1
    fi

    if [[ ! -d "$source_dir" ]]; then
        log "ERROR: Source directory not found: $source_dir"
        return 1
    fi

    local series_file="${component_patches_dir}/series.txt"
    log "=== Applying patches for ${component} (${version:-default}) ==="
    log "Source: $source_dir"
    log "Patches: $component_patches_dir"

    # Marker-file short-circuit: hash all patch files in the series, compare
    # against the per-component marker. If unchanged, the source is already
    # patched and we skip the per-patch loop entirely.
    #
    # This dodges a structural bug in the apply_patch() fallback chain:
    # `patch -R --dry-run` (the "already applied?" detector) cannot cleanly
    # reverse a patch whose immediate context has been modified by a LATER
    # patch in the series. The marker is authoritative; per-patch reverse-
    # detection is fragile and was the root cause of the round-5 failure
    # where 0004 hunk 3 reverse-failed because 0007 inserted bbdbg_log
    # calls into its context.
    #
    # Marker lives INSIDE the source dir (was under out/ historically — see
    # legacy_marker_file below for the migration). Inside-source ties the
    # marker's lifetime to the source's: a re-fetch / re-clone / docker volume
    # wipe destroys both together, so the marker can never falsely claim
    # patches are applied to a source that was just freshly extracted. The
    # earlier "outside the source tree so git reset doesn't nuke it" rationale
    # was wrong — `git reset --hard HEAD` does wipe the patches from the
    # source, so the marker SHOULD be invalidated in that case (and is,
    # because reset only touches tracked files; the marker is untracked).
    # `git clean -fd` would wipe it, but `git clean -fd` is paired with
    # `git reset --hard` in retry-clean / prepare-*.sh, which also wipes
    # the patches — exactly when the marker should be invalidated.
    local marker_file="${source_dir}/.patches-applied-${component}-${version:-default}"
    local legacy_marker_file="${REPRO_DIR}/out/.patches-applied-${component}-${version:-default}"
    local series_hash=""
    if [[ -d "$component_patches_dir" ]]; then
        series_hash=$(cat "${component_patches_dir}"/*.patch 2>/dev/null | sha256sum | cut -d' ' -f1)
    fi
    if [[ -n "$series_hash" && -f "$marker_file" && "$(cat "$marker_file" 2>/dev/null)" == "$series_hash" ]]; then
        log "  Series hash matches marker: $series_hash"
        log "=== All patches already applied (marker hit) for ${component} (${version:-default}) ==="
        return 0
    fi

    local failed=0
    if [[ -f "$series_file" ]]; then
        while IFS= read -r patch_name; do
            # Skip blank lines and comments
            [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue

            local patch_file="${component_patches_dir}/${patch_name}"
            if [[ ! -f "$patch_file" ]]; then
                log "  ✗ Patch file not found: $patch_file"
                failed=1
                break
            fi

            if ! apply_patch "$patch_file" "$source_dir"; then
                failed=1
                break
            fi
        done < "$series_file"
    else
        log "WARNING: series.txt not found; applying all *.patch files in lexical order"
        local patch_file
        local found_patch=0
        for patch_file in "${component_patches_dir}"/*.patch; do
            if [[ ! -f "$patch_file" ]]; then
                continue
            fi
            found_patch=1
            if ! apply_patch "$patch_file" "$source_dir"; then
                failed=1
                break
            fi
        done
        if [[ "$found_patch" -eq 0 ]]; then
            log "WARNING: No patch files found in $component_patches_dir"
        fi
    fi

    if [[ "$failed" -eq 0 ]]; then
        # Record the series hash so future runs can short-circuit. Marker is
        # written inside the source directory so its lifetime tracks the
        # source's — re-fetch wipes both together. See the marker comment
        # above the short-circuit check for the rationale.
        if [[ -n "$series_hash" ]]; then
            mkdir -p "$(dirname "$marker_file")"
            printf '%s\n' "$series_hash" > "$marker_file"
            log "  Wrote marker: $marker_file"
            # Migration cleanup: prior versions of this script wrote the
            # marker under repro/out/. The host-bind-mount survived
            # `docker compose down -v`, then masqueraded as a valid
            # "patches applied" signal against a freshly-cloned source.
            # Drop the legacy file now that the in-source marker is the
            # source of truth.
            if [[ -f "$legacy_marker_file" ]]; then
                rm -f "$legacy_marker_file"
                log "  Removed legacy marker: $legacy_marker_file"
            fi
        fi
        log "=== All patches applied successfully for ${component} (${version}) ==="
        return 0
    else
        log "=== FAILED: Some patches could not be applied for ${component} (${version}) ==="
        return 1
    fi
}

resolve_patch_version() {
    local component="$1"
    shift
    local candidate
    for candidate in "$@"; do
        [[ -z "$candidate" ]] && continue
        if [[ -d "${PATCHES_DIR}/${component}/${candidate}" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    printf ''
    return 1
}

# Entrypoint
main() {
    local component="${1:-all}"
    local version="${2:-}"

    log "========================================"
    log "Win98 Compatibility Patch Application"
    log "========================================"

    local failed=0

    if [[ "$component" == "all" ]]; then
        # Apply all known components using matrix-selected versions.
        local gcc_patch_version
        gcc_patch_version="$(resolve_patch_version "gcc" "${GCC_COMPONENT_VERSION:-}" "gcc-${GCC_COMPONENT_VERSION:-}")" || true
        if [[ -n "$gcc_patch_version" ]]; then
            apply_component "gcc" "$gcc_patch_version" || failed=1
        else
            log "WARNING: Could not resolve GCC patch version from matrix (GCC_COMPONENT_VERSION='${GCC_COMPONENT_VERSION:-}')"
        fi

        local mingw_patch_version
        mingw_patch_version="$(resolve_patch_version "mingw-w64" "${MINGW_W64_COMPONENT_VERSION:-}" "master")" || true
        if [[ -n "$mingw_patch_version" ]]; then
            apply_component "mingw-w64" "$mingw_patch_version" || failed=1
        else
            log "WARNING: Could not resolve mingw-w64 patch version from matrix (MINGW_W64_COMPONENT_VERSION='${MINGW_W64_COMPONENT_VERSION:-}')"
        fi

        local pthread_patch_version
        pthread_patch_version="$(resolve_patch_version "pthread9x" "${PTHREAD9X_COMPONENT_VERSION:-}" "master" "main")" || true
        if [[ -n "$pthread_patch_version" ]]; then
            apply_component "pthread9x" "$pthread_patch_version" || failed=1
        else
            log "WARNING: Could not resolve pthread9x patch version from matrix (PTHREAD9X_COMPONENT_VERSION='${PTHREAD9X_COMPONENT_VERSION:-}')"
        fi
    else
        if [[ -z "$version" && "$component" != "pthread9x" ]]; then
            log "ERROR: Version required for component $component"
            log "Usage: scripts/apply-patches.sh $component <version>"
            exit 1
        fi
        apply_component "$component" "$version" || failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        log "========================================"
        log "All patches applied successfully!"
        log "========================================"
        exit 0
    else
        log "========================================"
        log "Some patches failed to apply. Check log: $LOG_FILE"
        log "========================================"
        exit 1
    fi
}

main "$@"
