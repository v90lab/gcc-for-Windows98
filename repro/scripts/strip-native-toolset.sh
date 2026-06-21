#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# strip-native-toolset.sh - Strip debug info from native toolset binaries
# ============================================================================
# GCC's bootstrap defaults to building with -O2 -g, so cc1.exe / cc1plus.exe
# / gcc.exe / the binutils binaries all ship with full DWARF debug sections
# unless explicitly stripped. On a fresh build cc1plus.exe is ~319 MB and
# cc1.exe is ~299 MB — about 90% of which is .debug_*. We don't ship the
# toolchain for debugging GCC itself, so strip everything in place before
# the package step zips it up.
#
# Runs i686-w64-mingw32-strip across every .exe / .dll under
# out/native-toolset/. Idempotent — running on already-stripped binaries
# is a no-op. Quiet on per-file failure so an oddball file doesn't abort
# the whole pass; aggregate before/after totals logged so a regression is
# obvious.
#
# Why a separate step rather than `make install-strip` in the build scripts:
#   - One concept, one place. The build scripts already do enough.
#   - install-strip support varies across autotools projects (some don't
#     implement it, some do it wrong). Doing it ourselves is uniform.
#   - This script is idempotent and cheap; the install steps are not.
#
# Hardlinks: `cp -al`-style installs (e.g. gcc → c++.exe is a hardlink to
# cc1.exe's wrapper, ld → ld.bfd.exe) end up sharing inodes. Stripping
# follows the inode, so we deduplicate by inode before running strip to
# avoid wasted work + corrupted reports. Each hardlinked set gets stripped
# exactly once and all names see the result.
# ============================================================================

source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

TOOLSET_DIR="$ROOT_DIR/out/native-toolset"
CROSS_BIN_DIR="$ROOT_DIR/out/toolchain/bin"
STRIP="$CROSS_BIN_DIR/${TARGET}-strip"

# Caller script is the implicit input; if its strip logic changes (e.g. new
# patterns to skip) the step re-runs. We can't enumerate every .exe/.dll
# under the toolset as inputs without scaling poorly, so we trust the build
# steps upstream to bump their own sentinels when they re-install.
invalidate_if_stale strip-native-toolset
skip_if_done strip-native-toolset

require_dir "$TOOLSET_DIR" "native toolset not found at $TOOLSET_DIR"
require_executable "$STRIP" "missing strip: $STRIP"

# Aggregate size before strip.
pre_bytes=$(find "$TOOLSET_DIR" \( -name "*.exe" -o -name "*.dll" \) -printf '%s\n' 2>/dev/null \
              | awk '{s+=$1} END {print s+0}')
pre_files=$(find "$TOOLSET_DIR" \( -name "*.exe" -o -name "*.dll" \) 2>/dev/null | wc -l)
log "before strip: $pre_files files, $(numfmt --to=iec "$pre_bytes" 2>/dev/null || echo "$pre_bytes bytes")"

# Strip in-place. Dedupe by inode so we don't re-strip hardlinked copies.
# %i = inode, %p = path; sort -u on the inode column gives one representative
# path per inode set.
stripped=0
failed=0
while IFS= read -r path; do
    if "$STRIP" --strip-unneeded "$path" 2>/dev/null; then
        stripped=$((stripped + 1))
    else
        # --strip-unneeded can refuse certain section layouts; fall back to
        # plain --strip-all which is more permissive.
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
# Sanity: post must be smaller-or-equal. If it grew, something is very wrong.
if (( post_bytes > pre_bytes )); then
    die "post-strip total ($post_bytes) > pre ($pre_bytes) — strip somehow added bytes"
fi
saved=$(( pre_bytes - post_bytes ))
log "saved $(numfmt --to=iec "$saved" 2>/dev/null || echo "$saved bytes") on native toolset"

mark_done strip-native-toolset
