#!/usr/bin/env bash
# ==============================================================================
# Run Script for Waydroid Remote Low-Latency Server
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PRESET="${1:-1080p}"
CONTROL_PORT="${2:-8000}"
VIDEO_PORT="${3:-8001}"

echo "============================================================"
echo "  Khởi chạy Waydroid Remote Server (Arch Linux + Hyprland)   "
echo "  Preset:       $PRESET"
echo "  Control Port: $CONTROL_PORT"
echo "  Video Port:   $VIDEO_PORT"
echo "============================================================"

exec python3 server/waydroid_touch_server.py \
    --preset "$PRESET" \
    --port "$CONTROL_PORT" \
    --video-port "$VIDEO_PORT"
