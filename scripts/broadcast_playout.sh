#!/bin/bash

CHANNEL_DIR="$1"
OUTPUT_ID="$2"

CHANNEL_CONFIG="$CHANNEL_DIR/channel.json"
CHANNELS_ROOT="${CHANNEL_ROOT:-$(dirname "$CHANNEL_DIR")}"
SETTINGS="${STREAMING_ENGINE_CONFIG:-${CHANNELS_ROOT}/system/settings.json}"
OUTPUT_CONFIG="$CHANNEL_DIR/outputs/${OUTPUT_ID}.json"
HUMAN_PLAYLIST="$CHANNEL_DIR/$(jq -r '.files.human_playlist // "playlists/human_playlist.json"' "$CHANNEL_CONFIG")"

OUTPUT_DIR=$(jq -r '.hls.output_dir // "${HLS_ROOT:-/var/www/html/hls}/channel1"' "$OUTPUT_CONFIG")

LOG_DIR="$CHANNEL_DIR/runtime/logs"
PID_DIR="$CHANNEL_DIR/runtime/pids"
STATUS_DIR="$CHANNEL_DIR/runtime/status"
CACHE_DIR="$CHANNEL_DIR/runtime/cache/${OUTPUT_ID}"

mkdir -p "$OUTPUT_DIR" "$LOG_DIR" "$PID_DIR" "$STATUS_DIR" "$CACHE_DIR"

LOG_FILE="$LOG_DIR/${OUTPUT_ID}.log"
STATUS_FILE="$STATUS_DIR/${OUTPUT_ID}.json"

MASTER_M3U8="$OUTPUT_DIR/stream.m3u8"
VIDEO_M3U8="$OUTPUT_DIR/video.m3u8"
AUDIO_M3U8="$OUTPUT_DIR/audio.m3u8"

VIDEO_FIFO="$CACHE_DIR/video.h264"
AUDIO_FIFO="$CACHE_DIR/audio.pcm"

HLS_TIME=2
HLS_LIST_SIZE=12
FPS=30
GOP=60

pkill -9 -f "ffmpeg.*video.h264" || true
pkill -9 -f "ffmpeg.*audio.pcm" || true
pkill -9 -f "ffmpeg.*video.m3u8" || true
pkill -9 -f "ffmpeg.*audio.m3u8" || true

rm -f "$OUTPUT_DIR"/*.ts "$OUTPUT_DIR"/*.m3u8
rm -f "$VIDEO_FIFO" "$AUDIO_FIFO"

mkfifo "$VIDEO_FIFO"
mkfifo "$AUDIO_FIFO"

exec 7<>"$VIDEO_FIFO"
exec 8<>"$AUDIO_FIFO"

cat > "$MASTER_M3U8" <<M3U
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Program Audio",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=4500000,AVERAGE-BANDWIDTH=4200000,RESOLUTION=1920x1080,FRAME-RATE=30.000,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
video.m3u8
M3U

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Separate synced A/V HLS started" >> "$LOG_FILE"

write_status() {
  cat > "$STATUS_FILE" <<JSON
{
  "output_id": "$OUTPUT_ID",
  "status": "running",
  "pid": $$,
  "mode": "separate-synced-av-hls",
  "hls_time": $HLS_TIME,
  "gop": $GOP,
  "updated_at": "$(date --iso-8601=seconds)"
}
JSON
}

video_hls_encoder() {
  ffmpeg -hide_banner -y \
    -fflags +genpts \
    -thread_queue_size 4096 \
    -f h264 \
    -framerate "$FPS" \
    -i "$VIDEO_FIFO" \
    -map 0:v:0 \
    -an \
    -c:v libx264 \
    -preset veryfast \
    -r "$FPS" \
    -g "$GOP" \
    -keyint_min "$GOP" \
    -sc_threshold 0 \
    -force_key_frames "expr:gte(t,n_forced*${HLS_TIME})" \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags delete_segments+independent_segments+program_date_time \
    -hls_segment_filename "$OUTPUT_DIR/video_%05d.ts" \
    -hls_start_number_source epoch \
    "$VIDEO_M3U8" >> "$LOG_FILE" 2>&1
}

audio_hls_encoder() {
  ffmpeg -hide_banner -y \
    -fflags +genpts+nobuffer \
    -flags low_delay \
    -thread_queue_size 1024 \
    -f s16le \
    -ar 48000 \
    -ac 2 \
    -i "$AUDIO_FIFO" \
    -c:a aac \
    -b:a 128k \
    -ar 48000 \
    -ac 2 \
    -f hls \
    -hls_time "$HLS_TIME" \
    -hls_list_size "$HLS_LIST_SIZE" \
    -hls_flags delete_segments+independent_segments+program_date_time \
    -hls_segment_filename "$OUTPUT_DIR/audio_%05d.ts" \
    -hls_start_number_source epoch \
    "$AUDIO_M3U8" >> "$LOG_FILE" 2>&1
}

build_video_concat() {
  CONCAT_FILE="$CACHE_DIR/video_concat.txt"
  rm -f "$CONCAT_FILE"

  jq -r 'sort_by(.order) | .[] | select(.enabled == true) | "file '\''" + .file + "'\''"' "$HUMAN_PLAYLIST" > "$CONCAT_FILE"

  echo "$CONCAT_FILE"
}

video_feed_loop() {
  while true; do
    CONCAT_FILE="$(build_video_concat)"

    if [ ! -s "$CONCAT_FILE" ]; then
      sleep 2
      continue
    fi

    ffmpeg -hide_banner -y -re -stream_loop -1 \
      -f concat -safe 0 -i "$CONCAT_FILE" \
      -map 0:v:0 \
      -an \
      -c:v libx264 -preset veryfast \
      -g "$GOP" \
      -r "$FPS" \
      -b:v 4000k \
      -maxrate 4000k \
      -bufsize 8000k \
      -bsf:v h264_mp4toannexb \
      -f h264 \
      "$VIDEO_FIFO" >> "$LOG_FILE" 2>&1

    sleep 1
  done
}

duration_for_item() {
  ITEM="$1"
  FILE=$(echo "$ITEM" | jq -r '.file')
  DUR=$(echo "$ITEM" | jq -r '.duration_seconds // empty')

  if [ -z "$DUR" ] || [ "$DUR" = "null" ] || [ "$DUR" = "0" ]; then
    DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)
  fi

  echo "${DUR:-5}"
}

feed_audio_item() {
  ITEM="$1"

  FILE=$(echo "$ITEM" | jq -r '.file')
  AUDIO_ID=$(echo "$ITEM" | jq -r '.audio_source_id // "embedded"')
  DUR=$(duration_for_item "$ITEM")

  AUDIO_TYPE=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .type' "$SETTINGS" | head -1)
  AUDIO_URL=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .url' "$SETTINGS" | head -1)

  AUDIO_TYPE="${AUDIO_TYPE:-embedded}"
  AUDIO_URL="${AUDIO_URL:-}"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] AUDIO ITEM: $AUDIO_ID/$AUDIO_TYPE duration=$DUR" >> "$LOG_FILE"

  if [ "$AUDIO_TYPE" = "embedded" ] || [ "$AUDIO_ID" = "embedded" ]; then

    ffmpeg -hide_banner -y -re \
      -i "$FILE" \
      -map 0:a:0? \
      -vn \
      -f s16le \
      -ar 48000 \
      -ac 2 \
      "$AUDIO_FIFO" >> "$LOG_FILE" 2>&1

  elif [ "$AUDIO_TYPE" = "silent" ] || [ "$AUDIO_ID" = "silent" ]; then

    ffmpeg -hide_banner -y -re \
      -f lavfi \
      -t "$DUR" \
      -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
      -f s16le \
      -ar 48000 \
      -ac 2 \
      "$AUDIO_FIFO" >> "$LOG_FILE" 2>&1

  else

    ffmpeg -hide_banner -y \
      -fflags nobuffer \
      -flags low_delay \
      -reconnect 1 \
      -reconnect_streamed 1 \
      -reconnect_delay_max 10 \
      -i "$AUDIO_URL" \
      -t "$DUR" \
      -vn \
      -f s16le \
      -ar 48000 \
      -ac 2 \
      "$AUDIO_FIFO" >> "$LOG_FILE" 2>&1

  fi
}

audio_feed_loop() {
  while true; do
    mapfile -t ITEMS < <(jq -c 'sort_by(.order) | .[] | select(.enabled == true)' "$HUMAN_PLAYLIST")

    if [ "${#ITEMS[@]}" -lt 1 ]; then
      sleep 2
      continue
    fi

    for ITEM in "${ITEMS[@]}"; do
      feed_audio_item "$ITEM"
    done
  done
}

write_status

video_hls_encoder &
echo "$!" > "$PID_DIR/${OUTPUT_ID}.video-hls.pid"

video_feed_loop &
echo "$!" > "$PID_DIR/${OUTPUT_ID}.video-feed.pid"

for i in $(seq 1 20); do
  if ls "$OUTPUT_DIR"/video_*.ts >/dev/null 2>&1; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Video segments detected, starting audio encoder/feed" >> "$LOG_FILE"
    break
  fi
  sleep 1
done

audio_hls_encoder &
echo "$!" > "$PID_DIR/${OUTPUT_ID}.audio-hls.pid"

sleep 1

audio_feed_loop &
echo "$!" > "$PID_DIR/${OUTPUT_ID}.audio-feed.pid"

wait

