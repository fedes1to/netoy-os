#!/bin/sh
set -e

# Test the netoy ISO under QEMU with serial console on stdio.
# Usage: ./scripts/qemu-serial.sh [iso-path]
#
# Press Ctrl+A then C inside QEMU to switch to the QEMU monitor,
# then "q" to quit, or just close the terminal.

ISO="${1:-}"
if [ -z "$ISO" ]; then
    # Pick the newest netoy ISO in out/.
    ISO=$(ls -t out/netoy-*-x86_64.iso 2>/dev/null | head -n1)
fi

if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
    echo "error: ISO not found"
    echo "build one first with ./build.sh or pass the path as argument"
    exit 1
fi

shift 2>/dev/null || true

echo "Booting $ISO on QEMU serial console..."
exec qemu-system-x86_64 \
    -m 2048 \
    -cdrom "$ISO" \
    -boot d \
    -nographic \
    "$@"
