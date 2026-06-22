#!/usr/bin/env bash
set -euo pipefail
# retry-clean.sh — smart retry: git-reset sources, keep clones intact
# Only cleans build artifacts (out/, logs/), NEVER deletes src/

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"

echo "=== retry-clean: git-reset sources, keep clones ==="

# With src/ on a named docker volume, the source clones live inside the
# container, not on the host bind mount. Run git ops via docker compose exec.
# Start the toolchain-builder if it isn't already running.
ensure_builder_running() {
  local cid state
  cid=$(docker compose -f "$COMPOSE_FILE" ps --quiet toolchain-builder 2>/dev/null | head -n1)
  if [[ -n "$cid" ]]; then
    state=$(docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null || echo "")
    if [[ "$state" == "running" ]]; then
      return 0
    fi
  fi
  echo "  starting toolchain-builder for retry-clean..."
  docker compose -f "$COMPOSE_FILE" up -d toolchain-builder >/dev/null
}

ensure_builder_running

# git reset every source clone that still has a .git/. Tarball-extracted
# sources (no .git/) are immutable extractions — leave them alone.
for repo in gcc binutils-gdb mingw-w64 pthread9x busybox-w32 make ctags diffutils patch muon jq; do
  if docker compose -f "$COMPOSE_FILE" exec -T toolchain-builder \
        test -d "/work/src/$repo/.git" 2>/dev/null; then
    echo "  git reset $repo..."
    docker compose -f "$COMPOSE_FILE" exec -T toolchain-builder bash -c "
      git -C /work/src/$repo reset --hard HEAD 2>/dev/null || true
      git -C /work/src/$repo clean -fd 2>/dev/null || true
    "
  fi
done

# Clean host-visible artifacts. With named volumes for build/ and src/,
# repro/build/ and repro/src/ on the host are empty/invisible — host-side
# rm on those is harmless. To wipe the build/ or src/ named volumes, run
# `docker compose down -v`.
echo "  cleaning out/ logs/ on host"
rm -rf "$PROJECT_DIR/out" "$PROJECT_DIR/logs" 2>/dev/null || true
mkdir -p "$PROJECT_DIR/out" "$PROJECT_DIR/logs"
touch "$PROJECT_DIR/out/.gitkeep"

echo "=== retry-clean done ==="
