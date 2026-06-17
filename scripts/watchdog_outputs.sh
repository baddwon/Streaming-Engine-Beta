#!/bin/bash
set -euo pipefail

CHANNEL_ROOT="${CHANNEL_ROOT:-/var/lib/streaming-engine-beta/channels}"
HLS_ROOT="${HLS_ROOT:-/var/www/html/hls}"
STALE_SECONDS="${STALE_SECONDS:-90}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

now="$(date +%s)"

for channel_dir in "$CHANNEL_ROOT"/*; do
  [ -d "$channel_dir" ] || continue
  [ "$(basename "$channel_dir")" = "system" ] && continue
  [ -f "$channel_dir/channel.json" ] || continue

  channel_id="$(basename "$channel_dir")"
  stream_file="$HLS_ROOT/Ch_${channel_id}/stream.m3u8"
  status_file="$channel_dir/runtime/status/hls-main.json"
  log_dir="$channel_dir/runtime/logs"
  mkdir -p "$log_dir"
  watchdog_log="$log_dir/watchdog.log"

  [ -f "$status_file" ] || continue
  status="$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null || echo unknown)"
  [ "$status" = "running" ] || continue

  if [ ! -f "$stream_file" ]; then
    echo "[$(date '+%F %T')] Missing HLS playlist for channel $channel_id; restarting hls-main" >> "$watchdog_log"
    "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
    "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
    continue
  fi

  mtime="$(stat -c %Y "$stream_file" 2>/dev/null || echo 0)"
  age=$((now - mtime))

  if [ "$age" -gt "$STALE_SECONDS" ]; then
    echo "[$(date '+%F %T')] Stale HLS playlist for channel $channel_id age=${age}s; restarting hls-main" >> "$watchdog_log"
    "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
    "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
  fi
done
