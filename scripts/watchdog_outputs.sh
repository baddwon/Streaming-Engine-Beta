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

probe_audio_url() {
  local url="$1"
  [ -n "$url" ] || return 1
  timeout 12 ffprobe -v error \
    -rw_timeout 8000000 \
    -timeout 8000000 \
    -user_agent "CustomStreamingEngine/0.3" \
    -select_streams a:0 \
    -show_entries stream=codec_type \
    -of csv=p=0 "$url" >/dev/null 2>&1
}

set_audio_fallback() {
  local channel_dir="$1"
  local reason="$2"
  local fallback_file="$channel_dir/runtime/status/audio-fallback.json"
  mkdir -p "$channel_dir/runtime/status"
  cat > "$fallback_file" <<EOF
{
  "active": true,
  "reason": "$reason",
  "activated_at": "$(date -Is)",
  "retry_count": 0
}
EOF
}

clear_audio_fallback() {
  local channel_dir="$1"
  local fallback_file="$channel_dir/runtime/status/audio-fallback.json"
  rm -f "$fallback_file"
}

bump_audio_retry() {
  local channel_dir="$1"
  local reason="$2"
  local fallback_file="$channel_dir/runtime/status/audio-retry.json"
  mkdir -p "$channel_dir/runtime/status"
  local count=0
  if [ -f "$fallback_file" ]; then
    count="$(jq -r '.retry_count // 0' "$fallback_file" 2>/dev/null || echo 0)"
  fi
  count=$((count + 1))
  cat > "$fallback_file" <<EOF
{
  "retry_count": $count,
  "last_reason": "$reason",
  "last_retry_at": "$(date -Is)"
}
EOF
  echo "$count"
}

reset_audio_retry() {
  rm -f "$1/runtime/status/audio-retry.json"
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

  AUDIO_ID="$(jq -r '.active_audio_source_id // "embedded"' "$channel_config" 2>/dev/null || echo embedded)"
  AUDIO_TYPE="$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .type' "$settings_file" 2>/dev/null | head -1)"
  AUDIO_URL="$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .url' "$settings_file" 2>/dev/null | head -1)"
  AUDIO_TYPE="${AUDIO_TYPE:-embedded}"
  AUDIO_URL="${AUDIO_URL:-}"

  if [ -f "$fallback_file" ] && [ "$AUDIO_TYPE" = "web" ] && [ -n "$AUDIO_URL" ]; then
    if probe_audio_url "$AUDIO_URL"; then
      log_event "$channel_dir" "INFO" "External audio probe succeeded; restoring $AUDIO_ID"
      clear_audio_fallback "$channel_dir"
      reset_audio_retry "$channel_dir"
      "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
      "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
      continue
    else
      log_event "$channel_dir" "WARN" "External audio still unavailable while in silent fallback: $AUDIO_ID"
    fi
  fi

  if [ ! -f "$stream_file" ]; then
    log_event "$channel_dir" "ERROR" "Missing HLS playlist for channel $channel_id; restarting hls-main"
    "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
    "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
    continue
  fi

  mtime="$(stat -c %Y "$stream_file" 2>/dev/null || echo 0)"
  age=$((now - mtime))

  if [ "$age" -gt "$STALE_SECONDS" ]; then
    log_event "$channel_dir" "ERROR" "Stale HLS playlist age=${age}s"

    if [ "$AUDIO_TYPE" = "web" ] && [ -n "$AUDIO_URL" ] && [ ! -f "$fallback_file" ]; then
      if probe_audio_url "$AUDIO_URL"; then
        retry_count="$(bump_audio_retry "$channel_dir" "hls stale but audio probe ok")"
        log_event "$channel_dir" "WARN" "Retrying web audio output; attempt ${retry_count}/3"
        "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
        "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
        continue
      else
        retry_count="$(bump_audio_retry "$channel_dir" "audio probe failed")"
        log_event "$channel_dir" "WARN" "External audio probe failed; attempt ${retry_count}/3"
        if [ "$retry_count" -ge 3 ]; then
          log_event "$channel_dir" "ERROR" "External audio failed after ${retry_count} attempts; switching to silent fallback"
          set_audio_fallback "$channel_dir" "External audio failed after retries"
        fi
        "$SCRIPT_DIR/stop_output.sh" "$channel_dir" hls-main || true
        "$SCRIPT_DIR/start_output.sh" "$channel_dir" hls-main || true
        continue
      fi
    fi

    log_event "$channel_dir" "ERROR" "Restarting hls-main due to stale HLS"
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
      warning_hash="$(printf "%s" "$recent" | sha1sum | awk '{print $1}')"
      warning_state="$channel_dir/runtime/status/last-ffmpeg-warning.hash"
      last_hash=""
      [ -f "$warning_state" ] && last_hash="$(cat "$warning_state" 2>/dev/null || true)"
      if [ -n "$recent" ] && [ "$warning_hash" != "$last_hash" ]; then
        log_event "$channel_dir" "WARN" "Recent FFmpeg warning: $recent"
        echo "$warning_hash" > "$warning_state"
      fi
    fi
  fi
done
