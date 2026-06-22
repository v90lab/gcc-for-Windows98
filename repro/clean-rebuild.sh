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
#   but doesn't touch the named Docker volumes (gcc-win98-build,
#   gcc-win98-src) — these hold the actual /work/src/ checkouts and
#   /work/build/ artifacts on Windows+Docker-Desktop, where the host's
#   repro/build/ and repro/src/ are shadowed and unreachable.
#
# This script handles that volume wipe, plus removes the project's Docker
# images so the Dockerfile changes (apt list, pip3 install meson, ccache,
# etc.) are re-applied.
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
  - ./build.sh --clean --no-cache $*
      (wipes out/ in full incl. dotfile sentinels, plus build/ logs/;
       forces Docker rebuild without layer cache)

This destroys all build state. Source clones, intermediate build artifacts,
and built images all go. The next build starts from zero (~1-2 hours).
Preserved: .env, src/ on host (which is empty anyway on Docker volume hosts),
config.json, scripts/, and anything else under repro/ that isn't out/build/logs.
The ccache volume (gcc-win98-ccache) is declared external in docker-compose
and is intentionally NOT wiped — the compiler cache survives so the
post-rebuild .o phase still cache-hits where possible. To also nuke ccache:
  docker volume rm gcc-win98-ccache

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

# --- 2. Hand off to build.sh -------------------------------------------------
# build.sh --clean does `rm -rf out` (no glob), which wipes the directory
# wholesale including .status-* sentinels and .patches-applied-* markers.
echo "[*] Running ./build.sh --clean --no-cache $*"
exec "$SCRIPT_DIR/build.sh" --clean --no-cache "$@"
