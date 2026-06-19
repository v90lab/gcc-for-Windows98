#!/usr/bin/env bash

set -euo pipefail

ARTIFACT="$1"
PREFIX="$2"

echo "Installing $ARTIFACT to $PREFIX..."

rm -rf "$PREFIX"
mkdir -p "$PREFIX"

case "$ARTIFACT" in
    *.tar.xz|*.txz)
        tar -C "$PREFIX" --strip-components=1 -xJf "$ARTIFACT"
        ;;
    *.tar.gz|*.tgz)
        tar -C "$PREFIX" --strip-components=1 -xzf "$ARTIFACT"
        ;;
    *.zip)
        # unzip has no --strip-components; stage into a tmpdir then move the
        # single top-level directory's contents up. Mirrors tar's strip=1.
        STAGE=$(mktemp -d)
        trap 'rm -rf "$STAGE"' EXIT
        unzip -q -d "$STAGE" "$ARTIFACT"
        TOP=$(find "$STAGE" -mindepth 1 -maxdepth 1 -type d)
        if [[ -z "$TOP" || $(printf '%s\n' "$TOP" | wc -l) -ne 1 ]]; then
            echo "ERROR: $ARTIFACT does not have exactly one top-level directory" >&2
            exit 1
        fi
        shopt -s dotglob nullglob
        mv "$TOP"/* "$PREFIX"/
        shopt -u dotglob nullglob
        ;;
    *)
        echo "ERROR: unsupported archive extension: $ARTIFACT" >&2
        exit 1
        ;;
esac

echo "Installation complete."
