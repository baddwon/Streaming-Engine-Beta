#!/bin/bash
set -euo pipefail

CHANNEL_ROOT="${CHANNEL_ROOT:-/var/lib/streaming-engine-beta/channels}"
HLS_ROOT="${HLS_ROOT:-/var/www/html/hls}"
STALE_SECONDS="${STALE_SECONDS:-90}"
SPEED_WARN="${SPEED_WARN:-0.90}"
SPEED_RESTART="${SPEED_RESTART:-0.75}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
now="$(date +%s)"

log_event() {
  local channel_dir="$1"
  local level="$2"
  local message="$3"
  mkdir -p "$channel_dir/runtime/logs"
  echo "[$(date '+%F %T')] [$level] $message" >> "$channel_dir/runtime/logs/events.log"
}

for channel_dir in "$CHANNEL_ROOT"/*; do
  [ -d "$channel_dir" ] || continue
  [ "$(basename "$channel_dir")" = "system" ] && continue
  [ -f "$channel_dir/channel.json" ] || continue

  channel_id="$(basename "$channel_dir")"
  stream_file="$HLS_ROOT/Ch_${channel_id}/stream.m3u8"
  status_file="$channel_dir/runtime/status/hls-main.json"
  ffmpeg_log="$channel_dir/runtime/logs/hls-main.log"

  [ -f "$status_file" ] || continue
  status="$(jq -r '.status // "unknown"' "$status_file" 2>/dev/null || echo unknown)"
  [ "$status" = "running" ] || continue

  if [ ! -f "$stream_file" ]; then
    log_event "$channel_dir" "ERROR" "Missing HLS playlist for channel $channel_id; restarting hls-main"
    "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
    "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
    continue
  fi

  mtime="$(stat -c %Y "$stream_file" 2>/dev/null || echo 0)"
  age=$((now - mtime))

  if [ "$age" -gt "$STALE_SECONDS" ]; then
    log_event "$channel_dir" "ERROR" "Stale HLS playlist age=${age}s; restarting hls-main"
    "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
    "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
    continue
  fi

  if [ -f "$ffmpeg_log" ]; then
    speed="$(grep -o 'speed=[0-9.]*x' "$ffmpeg_log" | tail -1 | sed 's/speed=//;s/x//' || true)"
    if [ -n "$speed" ]; then
      below_restart="$(awk -v s="$speed" -v t="$SPEED_RESTART" 'BEGIN{print (s<t)?1:0}')"
      below_warn="$(awk -v s="$speed" -v t="$SPEED_WARN" 'BEGIN{print (s<t)?1:0}')"
      if [ "$below_restart" = "1" ]; then
        log_event "$channel_dir" "ERROR" "FFmpeg speed ${speed}x below restart threshold ${SPEED_RESTART}; restarting hls-main"
        "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
        "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
      elif [ "$below_warn" = "1" ]; then
        log_event "$channel_dir" "WARN" "FFmpeg speed ${speed}x below warning threshold ${SPEED_WARN}"
      fi
    fi

    if grep -iE "Input/output error|Will reconnect|Error during demuxing|Invalid data" "$ffmpeg_log" | tail -5 >/dev/null 2>&1; then
      recent="$(grep -iE "Input/output error|Will reconnect|Error during demuxing|Invalid data" "$ffmpeg_log" | tail -1 || true)"
      [ -n "$recent" ] && log_event "$channel_dir" "WARN" "Recent FFmpeg warning: $recent"
    fi
  fi
done
