#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHANNEL_DIR="$1"
OUTPUT_ID="$2"

if [ -f "$SCRIPT_DIR/detect_system.sh" ]; then
  . "$SCRIPT_DIR/detect_system.sh" >/dev/null 2>&1 || true
fi

if [ -f /tmp/custom-streaming-encoder.env ]; then
  . /tmp/custom-streaming-encoder.env
fi

VIDEO_ENCODER="${VIDEO_ENCODER:-x264}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

CHANNELS_ROOT="${CHANNEL_ROOT:-$(dirname "$CHANNEL_DIR")}"
SETTINGS="${STREAMING_ENGINE_CONFIG:-${CHANNELS_ROOT}/system/settings.json}"
OUTPUT_GAIN_DB=$(jq -r '.output_gain_db // 0' "$SETTINGS" 2>/dev/null)
LIMITER_LIMIT=$(jq -r '.limiter_limit // 0.90' "$SETTINGS" 2>/dev/null)

OUTPUT_GAIN_DB="${OUTPUT_GAIN_DB:-0}"
LIMITER_LIMIT="${LIMITER_LIMIT:-0.90}"
AUDIO_FILTER="volume=${OUTPUT_GAIN_DB}dB"

OUTPUT_CONFIG="$CHANNEL_DIR/outputs/${OUTPUT_ID}.json"
CHANNEL_CONFIG="$CHANNEL_DIR/channel.json"

CHANNEL_ENCODER_REQUESTED="$(jq -r '.video_encoder_requested // empty' "$CHANNEL_CONFIG" 2>/dev/null)"
if [ -n "$CHANNEL_ENCODER_REQUESTED" ]; then
  export VIDEO_ENCODER_REQUESTED="$CHANNEL_ENCODER_REQUESTED"
fi

if [ -f "$SCRIPT_DIR/detect_system.sh" ]; then
  . "$SCRIPT_DIR/detect_system.sh" >/dev/null 2>&1 || true
fi

if [ -f /tmp/custom-streaming-encoder.env ]; then
  . /tmp/custom-streaming-encoder.env
fi

OUTPUT_DIR=$(jq -r '.hls.output_dir // "${HLS_ROOT:-/var/www/html/hls}/default"' "$OUTPUT_CONFIG")
OUTPUT_FILE=$(jq -r '.hls.output_file // "stream.m3u8"' "$OUTPUT_CONFIG")
HLS_TIME=$(jq -r '.hls.hls_time // 4' "$OUTPUT_CONFIG")
HLS_LIST_SIZE=$(jq -r '.hls.hls_list_size // 24' "$OUTPUT_CONFIG")

TARGET="$OUTPUT_DIR/$OUTPUT_FILE"
PLAYLIST="$CHANNEL_DIR/playlists/ffmpeg_playlist.txt"

LOG_DIR="$CHANNEL_DIR/runtime/logs"
PID_DIR="$CHANNEL_DIR/runtime/pids"
STATUS_DIR="$CHANNEL_DIR/runtime/status"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$PID_DIR" "$STATUS_DIR"

LOG_FILE="$LOG_DIR/${OUTPUT_ID}.log"
PID_FILE="$PID_DIR/${OUTPUT_ID}.pid"
STATUS_FILE="$STATUS_DIR/${OUTPUT_ID}.json"

pkill -9 -f "ffmpeg.*${TARGET}" || true

rm -f "$OUTPUT_DIR"/*.ts "$OUTPUT_DIR"/*.m3u8 "$OUTPUT_DIR"/*.tmp

AUDIO_ID=$(jq -r '.active_audio_source_id // "embedded"' "$CHANNEL_CONFIG" 2>/dev/null)

AUDIO_TYPE=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .type' "$SETTINGS" | head -1)
AUDIO_URL=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .url' "$SETTINGS" | head -1)

AUDIO_ID="${AUDIO_ID:-embedded}"
AUDIO_TYPE="${AUDIO_TYPE:-embedded}"
AUDIO_URL="${AUDIO_URL:-}"

AUDIO_EFFECTIVE_ID="$AUDIO_ID"
AUDIO_EFFECTIVE_TYPE="$AUDIO_TYPE"
AUDIO_EFFECTIVE_URL="$AUDIO_URL"
AUDIO_FALLBACK_FILE="$STATUS_DIR/audio-fallback.json"

if [ -f "$AUDIO_FALLBACK_FILE" ]; then
  FALLBACK_ACTIVE="$(jq -r '.active // false' "$AUDIO_FALLBACK_FILE" 2>/dev/null || echo false)"
  if [ "$FALLBACK_ACTIVE" = "true" ]; then
    AUDIO_EFFECTIVE_ID="silent"
    AUDIO_EFFECTIVE_TYPE="silent"
    AUDIO_EFFECTIVE_URL=""
    echo "[$(date '+%F %T')] [WARN] Audio fallback active; using silence instead of $AUDIO_ID" >> "$LOG_DIR/events.log"
  fi
fi

COMMON_HLS_ARGS=(
  -f hls
  -hls_time "$HLS_TIME"
  -hls_list_size "$HLS_LIST_SIZE"
  -hls_delete_threshold "$HLS_LIST_SIZE"
  -hls_flags delete_segments+independent_segments+temp_file
  -hls_segment_filename "$OUTPUT_DIR/segment_%05d.ts"
  "$TARGET"
)

if [ "$VIDEO_ENCODER" = "vaapi" ]; then
  VIDEO_ARGS=(
    -vaapi_device "$VAAPI_DEVICE"
    -vf "format=nv12,hwupload"
    -c:v h264_vaapi
    -b:v 4000k
    -maxrate 4000k
    -bufsize 8000k
    -r 30
    -g 120
    -keyint_min 120
    -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*4)"
  )
elif [ "$VIDEO_ENCODER" = "nvenc" ]; then
  VIDEO_ARGS=(
    -c:v h264_nvenc
    -preset p4
    -b:v 4000k
    -maxrate 4000k
    -bufsize 8000k
    -r 30
    -g 120
    -keyint_min 120
    -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*4)"
  )
else
  VIDEO_ARGS=(
    -c:v libx264
    -preset veryfast
    -b:v 4000k
    -maxrate 4000k
    -bufsize 8000k
    -r 30
    -g 120
    -keyint_min 120
    -sc_threshold 0
    -force_key_frames "expr:gte(t,n_forced*4)"
  )
fi

if [ "$AUDIO_EFFECTIVE_TYPE" = "web" ] && [ -n "$AUDIO_EFFECTIVE_URL" ]; then
  ffmpeg -hide_banner -y \
    -re -stream_loop -1 -f concat -safe 0 -i "$PLAYLIST" \
    -thread_queue_size 1024 -reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_on_network_error 1 -reconnect_delay_max 10 -rw_timeout 15000000 -timeout 15000000 -user_agent "CustomStreamingEngine/0.3" -i "$AUDIO_EFFECTIVE_URL" \
    -map 0:v:0 \
    -map 1:a:0 \
    "${VIDEO_ARGS[@]}" \
    -af "$AUDIO_FILTER" \
    -c:a aac -b:a 128k -ar 48000 -ac 2 \
    "${COMMON_HLS_ARGS[@]}" >> "$LOG_FILE" 2>&1 &
elif [ "$AUDIO_EFFECTIVE_TYPE" = "silent" ]; then
  ffmpeg -hide_banner -y \
    -re -stream_loop -1 -f concat -safe 0 -i "$PLAYLIST" \
    -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=48000 \
    -map 0:v:0 \
    -map 1:a:0 \
    "${VIDEO_ARGS[@]}" \
    -c:a aac -b:a 128k -ar 48000 -ac 2 \
    -shortest \
    "${COMMON_HLS_ARGS[@]}" >> "$LOG_FILE" 2>&1 &
else
  ffmpeg -hide_banner -y \
    -re -stream_loop -1 -f concat -safe 0 -i "$PLAYLIST" \
    -map 0:v:0 \
    -map 0:a:0? \
    "${VIDEO_ARGS[@]}" \
    -af "$AUDIO_FILTER" \
    -c:a aac -b:a 128k -ar 48000 -ac 2 \
    "${COMMON_HLS_ARGS[@]}" >> "$LOG_FILE" 2>&1 &
fi

PID=$!
echo "$PID" > "$PID_FILE"

STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$STATUS_FILE" <<JSON
{
  "output_id": "$OUTPUT_ID",
  "status": "running",
  "pid": $PID,
  "started_at": "$STARTED_AT",
  "mode": "live-hls",
  "video_encoder": "$VIDEO_ENCODER",
  "output_gain_db": "$OUTPUT_GAIN_DB",
  "limiter_limit": "$LIMITER_LIMIT",
  "audio_source_id": "$AUDIO_ID",
  "audio_effective_id": "$AUDIO_EFFECTIVE_ID",
  "audio_source_type": "$AUDIO_TYPE",
  "audio_effective_type": "$AUDIO_EFFECTIVE_TYPE",
  "audio_source_url": "$AUDIO_URL",
  "audio_fallback_active": "$(jq -r '.active // false' "$AUDIO_FALLBACK_FILE" 2>/dev/null || echo false)"
}
JSON
