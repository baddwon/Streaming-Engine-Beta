#!/bin/bash

CHANNEL_DIR="$1"
OUTPUT_ID="$2"

OUTPUT_CONFIG="$CHANNEL_DIR/outputs/${OUTPUT_ID}.json"
CHANNEL_CONFIG="$CHANNEL_DIR/channel.json"

OUTPUT_DIR=$(jq -r '.hls.output_dir // "/var/www/html/hls/channel1"' "$OUTPUT_CONFIG")
OUTPUT_FILE=$(jq -r '.hls.output_file // "stream.m3u8"' "$OUTPUT_CONFIG")
TARGET="$OUTPUT_DIR/$OUTPUT_FILE"
PLAYLIST="$CHANNEL_DIR/playlists/ffmpeg_playlist.txt"

LOG_DIR="$CHANNEL_DIR/runtime/logs"
PID_DIR="$CHANNEL_DIR/runtime/pids"
STATUS_DIR="$CHANNEL_DIR/runtime/status"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$PID_DIR" "$STATUS_DIR"

LOG_FILE="$LOG_DIR/${OUTPUT_ID}.log"
PID_FILE="$PID_DIR/${OUTPUT_ID}.pid"
STATUS_FILE="$STATUS_DIR/${OUTPUT_ID}.json"

pkill -9 -f "ffmpeg.*stream.m3u8" || true
pkill -9 -f "broadcast_playout" || true

rm -f "$OUTPUT_DIR"/*.ts "$OUTPUT_DIR"/*.m3u8

AUDIO_ID=$(jq -r '
  sort_by(.order)
  | .[]
  | select(.enabled == true)
  | .audio_source_id // "embedded"
' "$CHANNEL_DIR/playlists/human_playlist.json" | head -1)

AUDIO_TYPE=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .type' "$CHANNEL_CONFIG" | head -1)
AUDIO_URL=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .url' "$CHANNEL_CONFIG" | head -1)

AUDIO_TYPE="${AUDIO_TYPE:-embedded}"

if [ "$AUDIO_TYPE" = "web" ]; then
  ffmpeg -hide_banner -y -re -stream_loop -1 \
    -f concat -safe 0 -i "$PLAYLIST" \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 10 \
    -i "$AUDIO_URL" \
    -map 0:v:0 -map 1:a:0 \
    -vaapi_device /dev/dri/renderD128 \
    -vf format=nv12,hwupload \
    -c:v h264_vaapi -b:v 4000k -maxrate 4000k -bufsize 8000k -r 30 -g 60 \
    -c:a aac -b:a 128k -ar 48000 -ac 2 \
    -f hls -hls_time 4 -hls_list_size 12 \
    -hls_flags delete_segments+independent_segments \
    -hls_segment_filename "$OUTPUT_DIR/segment_%05d.ts" \
    "$TARGET" >> "$LOG_FILE" 2>&1 &
else
  ffmpeg -hide_banner -y -re -stream_loop -1 \
    -f concat -safe 0 -i "$PLAYLIST" \
    -map 0:v:0 -map 0:a:0? \
    -vaapi_device /dev/dri/renderD128 \
    -vf format=nv12,hwupload \
    -c:v h264_vaapi -b:v 4000k -maxrate 4000k -bufsize 8000k -r 30 -g 60 \
    -c:a aac -b:a 128k -ar 48000 -ac 2 \
    -f hls -hls_time 4 -hls_list_size 12 \
    -hls_flags delete_segments+independent_segments \
    -hls_segment_filename "$OUTPUT_DIR/segment_%05d.ts" \
    "$TARGET" >> "$LOG_FILE" 2>&1 &
fi

PID=$!
echo "$PID" > "$PID_FILE"

cat > "$STATUS_FILE" <<JSON
{
  "output_id": "$OUTPUT_ID",
  "status": "running",
  "pid": $PID,
  "mode": "recovery-concat-single-audio",
  "audio_source_id": "$AUDIO_ID",
  "audio_source_type": "$AUDIO_TYPE",
  "audio_source_url": "$AUDIO_URL"
}
JSON
