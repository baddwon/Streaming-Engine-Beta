#!/bin/bash

CHANNEL_DIR="$1"
OUTPUT_ID="${2:-hls-main}"

CHANNEL_CONFIG="$CHANNEL_DIR/channel.json"
HUMAN_PLAYLIST="$CHANNEL_DIR/$(jq -r '.files.human_playlist // "playlists/human_playlist.json"' "$CHANNEL_CONFIG")"

CACHE_DIR="$CHANNEL_DIR/runtime/cache/${OUTPUT_ID}"
LOG_DIR="$CHANNEL_DIR/runtime/logs"
LOG_FILE="$LOG_DIR/${OUTPUT_ID}.log"

ASSET="$CACHE_DIR/playout.mp4"
CONCAT_LIST="$CACHE_DIR/concat.txt"
ENABLED_SNAPSHOT="$CACHE_DIR/enabled_items.json"

mkdir -p "$CACHE_DIR" "$LOG_DIR"

rm -f "$CACHE_DIR"/segment_*.mp4
rm -f "$CONCAT_LIST"
rm -f "$ASSET"
rm -f "$ENABLED_SNAPSHOT"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] START generate_playout_asset" >> "$LOG_FILE"

jq 'sort_by(.order) | map(select(.enabled == true))' "$HUMAN_PLAYLIST" > "$ENABLED_SNAPSHOT"

ENABLED_COUNT=$(jq 'length' "$ENABLED_SNAPSHOT")
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Enabled item count: $ENABLED_COUNT" >> "$LOG_FILE"
cat "$ENABLED_SNAPSHOT" >> "$LOG_FILE"

if [ "$ENABLED_COUNT" -lt 1 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: no enabled items" >> "$LOG_FILE"
  exit 1
fi

INDEX=1

mapfile -t ITEMS < <(jq -c '.[]' "$ENABLED_SNAPSHOT")

for ITEM in "${ITEMS[@]}"; do

  FILE=$(echo "$ITEM" | jq -r '.file')
  TITLE=$(echo "$ITEM" | jq -r '.title // .file')
  AUDIO_ID=$(echo "$ITEM" | jq -r '.audio_source_id // "embedded"')
  DURATION=$(echo "$ITEM" | jq -r '.duration_seconds // empty')

  if [ -z "$DURATION" ] || [ "$DURATION" = "null" ] || [ "$DURATION" = "0" ]; then
    DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)
  fi

  if [ -z "$DURATION" ] || [ "$DURATION" = "null" ]; then
    DURATION=10
  fi

  SEGMENT="$CACHE_DIR/segment_$(printf "%04d" "$INDEX").mp4"

  AUDIO_TYPE=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .type' "$CHANNEL_CONFIG" | head -1)
  AUDIO_URL=$(jq -r --arg id "$AUDIO_ID" '.audio_sources[]? | select(.id == $id) | .url' "$CHANNEL_CONFIG" | head -1)

  AUDIO_TYPE="${AUDIO_TYPE:-embedded}"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] BUILD SEGMENT $INDEX" >> "$LOG_FILE"
  echo "  title=$TITLE" >> "$LOG_FILE"
  echo "  file=$FILE" >> "$LOG_FILE"
  echo "  duration=$DURATION" >> "$LOG_FILE"
  echo "  audio_id=$AUDIO_ID" >> "$LOG_FILE"
  echo "  audio_type=$AUDIO_TYPE" >> "$LOG_FILE"
  echo "  audio_url=$AUDIO_URL" >> "$LOG_FILE"
  echo "  segment=$SEGMENT" >> "$LOG_FILE"

  if [ ! -f "$FILE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SKIP SEGMENT $INDEX: missing source file" >> "$LOG_FILE"
    INDEX=$((INDEX + 1))
    continue
  fi

  if [ "$AUDIO_TYPE" = "embedded" ] || [ "$AUDIO_ID" = "embedded" ]; then

    ffmpeg -y \
      -hide_banner \
      -vaapi_device /dev/dri/renderD128 \
      -i "$FILE" \
      -t "$DURATION" \
      -map 0:v:0 \
      -map 0:a:0? \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=nv12,hwupload" \
      -c:v h264_vaapi \
      -b:v 4000k \
      -maxrate 4000k \
      -bufsize 8000k \
      -g 60 \
      -c:a aac \
      -b:a 128k \
      -ar 48000 \
      -ac 2 \
      -movflags +faststart \
      "$SEGMENT" >> "$LOG_FILE" 2>&1

  elif [ "$AUDIO_TYPE" = "silent" ] || [ "$AUDIO_ID" = "silent" ]; then

    ffmpeg -y \
      -hide_banner \
      -vaapi_device /dev/dri/renderD128 \
      -i "$FILE" \
      -f lavfi -t "$DURATION" -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
      -t "$DURATION" \
      -map 0:v:0 \
      -map 1:a:0 \
      -shortest \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=nv12,hwupload" \
      -c:v h264_vaapi \
      -b:v 4000k \
      -maxrate 4000k \
      -bufsize 8000k \
      -g 60 \
      -c:a aac \
      -b:a 128k \
      -ar 48000 \
      -ac 2 \
      -movflags +faststart \
      "$SEGMENT" >> "$LOG_FILE" 2>&1

  else

    ffmpeg -y \
      -hide_banner \
      -vaapi_device /dev/dri/renderD128 \
      -i "$FILE" \
      -thread_queue_size 4096 \
      -reconnect 1 \
      -reconnect_streamed 1 \
      -reconnect_delay_max 10 \
      -i "$AUDIO_URL" \
      -t "$DURATION" \
      -map 0:v:0 \
      -map 1:a:0 \
      -shortest \
      -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=nv12,hwupload" \
      -c:v h264_vaapi \
      -b:v 4000k \
      -maxrate 4000k \
      -bufsize 8000k \
      -g 60 \
      -c:a aac \
      -b:a 128k \
      -ar 48000 \
      -ac 2 \
      -movflags +faststart \
      "$SEGMENT" >> "$LOG_FILE" 2>&1

  fi

  if [ -s "$SEGMENT" ]; then
    SEG_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$SEGMENT" 2>/dev/null)
    echo "file '$SEGMENT'" >> "$CONCAT_LIST"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SEGMENT $INDEX OK duration=$SEG_DUR" >> "$LOG_FILE"
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SEGMENT $INDEX FAILED: output not created" >> "$LOG_FILE"
  fi

  INDEX=$((INDEX + 1))

done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] CONCAT LIST:" >> "$LOG_FILE"
cat "$CONCAT_LIST" >> "$LOG_FILE" 2>/dev/null || true

if [ ! -s "$CONCAT_LIST" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: concat list empty" >> "$LOG_FILE"
  exit 1
fi

ffmpeg -y \
  -hide_banner \
  -f concat \
  -safe 0 \
  -i "$CONCAT_LIST" \
  -c copy \
  -movflags +faststart \
  "$ASSET" >> "$LOG_FILE" 2>&1

if [ ! -s "$ASSET" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: playout asset not created" >> "$LOG_FILE"
  exit 1
fi

ASSET_DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$ASSET" 2>/dev/null)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] PLAYOUT ASSET READY duration=$ASSET_DUR file=$ASSET" >> "$LOG_FILE"

