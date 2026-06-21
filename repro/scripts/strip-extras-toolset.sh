#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# strip-extras-toolset.sh - Strip debug info from extras toolset binaries
# ============================================================================
# Companion to strip-native-toolset.sh; same logic, different target dir.
# The main offender in the extras toolset is gdb.exe (~144 MB unstripped,
# ~7 MB stripped). busybox.exe and the rest are smaller but also carry
# debug sections. See the native script's header for design rationale.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

TOOLSET_DIR="$ROOT_DIR/out/extras-toolset"
CROSS_BIN_DIR="$ROOT_DIR/out/toolchain/bin"
STRIP="$CROSS_BIN_DIR/${TARGET}-strip"

invalidate_if_stale strip-extras-toolset
skip_if_done strip-extras-toolset

require_dir "$TOOLSET_DIR" "extras toolset not found at $TOOLSET_DIR"
require_executable "$STRIP" "missing strip: $STRIP"

pre_bytes=$(find "$TOOLSET_DIR" \( -name "*.exe" -o -name "*.dll" \) -printf '%s\n' 2>/dev/null \
              | awk '{s+=$1} END {print s+0}')
pre_files=$(find "$TOOLSET_DIR" \( -name "*.exe" -o -name "*.dll" \) 2>/dev/null | wc -l)
log "before strip: $pre_files files, $(numfmt --to=iec "$pre_bytes" 2>/dev/null || echo "$pre_bytes bytes")"

stripped=0
failed=0
while IFS= read -r path; do
    if "$STRIP" --strip-unneeded "$path" 2>/dev/null; then
        stripped=$((stripped + 1))
    else
        if "$STRIP" --strip-all "$path" 2>/dev/null; then
            stripped=$((stripped + 1))
        else
            log "  WARN: strip refused $path"
            failed=$((failed + 1))
        fi
    fi
done < <(
    find "$TOOLSET_DIR" \( -name "*.exe" -o -name "*.dll" \) -printf '%i\t%p\n' \
      | sort -u -k1,1 \
      | cut -f2-
)

post_bytes=$(find "$TOOLSET_DIR" \( -name "*.exe" -o -name "*.dll" \) -printf '%s\n' 2>/dev/null \
               | awk '{s+=$1} END {print s+0}')
log "after strip: $pre_files files, $(numfmt --to=iec "$post_bytes" 2>/dev/null || echo "$post_bytes bytes"); stripped=$stripped failed=$failed"
if (( post_bytes > pre_bytes )); then
    die "post-strip total ($post_bytes) > pre ($pre_bytes) — strip somehow added bytes"
fi
saved=$(( pre_bytes - post_bytes ))
log "saved $(numfmt --to=iec "$saved" 2>/dev/null || echo "$saved bytes") on extras toolset"

mark_done strip-extras-toolset
