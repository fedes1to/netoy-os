#!/bin/sh
set -e

cd "$(dirname "$0")"
REPO_ROOT="$PWD"
NETOY_TUI="$REPO_ROOT/netoy-tui"
OUT="$REPO_ROOT/out"

mkdir -p "$OUT"

if [ ! -d "$NETOY_TUI" ]; then
    echo "error: netoy-tui not found at $NETOY_TUI"
    exit 1
fi

# Run the whole build inside an Alpine container. The repo is mounted at
# /work and the netoy-tui source is mounted read-only at /netoy-tui.
exec podman run --rm \
    -v "$REPO_ROOT:/work" \
    -v "$NETOY_TUI:/netoy-tui:ro" \
    -w /work \
    alpine:3.24 \
    sh /work/scripts/build-in-container.sh
