#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# clean-rebuild.sh - From-scratch rebuild (nukes everything build.sh --clean misses)
# ============================================================================
# Usage: ./clean-rebuild.sh [--yes|-y] [build.sh args...]
#   --yes, -y     Skip the confirmation prompt
#   ...           Any further args are forwarded to ./build.sh
#                 (e.g. --jobs 8, --matrix 0, --without-extras)
#
# Why this exists:
#   The on-host `--clean` flag in build.sh wipes repro/out/ /build/ /logs/
#   but misses two things:
#     1. Named Docker volumes (gcc-win98-build, gcc-win98-src) — these hold
#        the actual /work/src/ checkouts and /work/build/ artifacts on
#        Windows+Docker-Desktop, where the host's repro/build/ and repro/src/
#        are shadowed and unreachable.
#     2. Status sentinel dotfiles (out/.status-*) — bash's default glob
#        doesn't expand to dotfiles, so `rm -rf out/*` leaves them behind
#        and the next build skips already-done steps.
#
# This script handles both, plus removes the project's Docker images so the
# Dockerfile changes (apt list, pip3 install meson, etc.) are re-applied.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

AUTO_YES=""
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  AUTO_YES="yes"
  shift
fi

cat <<EOF
This will:
  - docker compose down -v --rmi local
      (stop containers, REMOVE named volumes gcc-win98-build + gcc-win98-src,
       REMOVE built toolchain-builder + consumer images)
  - rm -f $SCRIPT_DIR/out/.status-*
      (clear status sentinels build.sh --clean misses)
  - ./build.sh --clean --no-cache $*
      (wipes out/, build/, logs/; forces Docker rebuild without layer cache)

This destroys all build state. Source clones, intermediate build artifacts,
and built images all go. The next build starts from zero (~1-2 hours).
Preserved: .env, src/ on host (which is empty anyway on Docker volume hosts),
config.json, scripts/, and anything else under repro/ that isn't out/build/logs.

EOF

if [[ "$AUTO_YES" != "yes" ]]; then
  read -r -p "Proceed? [y/N] " reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

# --- 1. Stop containers, remove named volumes + project images ---------------
echo "[*] docker compose down -v --rmi local..."
docker compose -f "$COMPOSE_FILE" down -v --rmi local || true

# --- 2. Clear status sentinels (the dotfile gap in --clean) ------------------
echo "[*] Clearing status sentinels in $SCRIPT_DIR/out/..."
rm -f "$SCRIPT_DIR/out"/.status-* 2>/dev/null || true

# --- 3. Hand off to build.sh -------------------------------------------------
echo "[*] Running ./build.sh --clean --no-cache $*"
exec "$SCRIPT_DIR/build.sh" --clean --no-cache "$@"
