#!/bin/bash

CHANNEL_DIR="$1"
INPUT_FILE="$2"

if [ -f /tmp/custom-streaming-encoder.env ]; then
  . /tmp/custom-streaming-encoder.env
fi

VIDEO_ENCODER="${VIDEO_ENCODER:-x264}"

if [ -z "$CHANNEL_DIR" ] || [ -z "$INPUT_FILE" ]; then
  echo "Usage: prestage.sh <channel_dir> <input_file>"
  exit 1
fi

CONFIG="$CHANNEL_DIR/channel.json"

INCOMING="$CHANNEL_DIR/$(jq -r '.paths.incoming // "incoming"' "$CONFIG")"
PRODUCTION="$CHANNEL_DIR/$(jq -r '.paths.production // "production"' "$CONFIG")"
PROCESSED="$CHANNEL_DIR/$(jq -r '.paths.processed // "processed"' "$CONFIG")"
FAILED="$CHANNEL_DIR/$(jq -r '.paths.failed // "failed"' "$CONFIG")"
LOG_DIR="$CHANNEL_DIR/$(jq -r '.paths.logs // "runtime/logs"' "$CONFIG")"

mkdir -p "$INCOMING" "$PRODUCTION" "$PROCESSED" "$FAILED" "$LOG_DIR"

LOG_FILE="$LOG_DIR/prestage-watch.log"

BASENAME="$(basename "$INPUT_FILE")"
NAME_NO_EXT="${BASENAME%.*}"

COUNT=$(find "$PRODUCTION" -maxdepth 1 -type f -iname "*.mp4" | wc -l)
NEXT=$((COUNT + 1))
OUTFILE="$PRODUCTION/$(printf "%03d" "$NEXT")_${NAME_NO_EXT}.mp4"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Processing: $INPUT_FILE" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Output: $OUTFILE" >> "$LOG_FILE"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Encoder: $VIDEO_ENCODER" >> "$LOG_FILE"

if [ "$VIDEO_ENCODER" = "nvenc" ]; then
  ffmpeg -y -hide_banner \
  -i "$INPUT_FILE" \
  -map 0:v:0 \
  -map 0:a:0? \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=yuv420p" \
  -c:v h264_nvenc \
  -preset p4 \
  -b:v 4000k \
  -maxrate 4000k \
  -bufsize 8000k \
  -g 60 \
  -c:a aac \
  -b:a 192k \
  -ar 48000 \
  -ac 2 \
  -movflags +faststart \
  "$OUTFILE" >> "$LOG_FILE" 2>&1

elif [ "$VIDEO_ENCODER" = "vaapi" ]; then
  ffmpeg -y -hide_banner \
  -vaapi_device /dev/dri/renderD128 \
  -i "$INPUT_FILE" \
  -map 0:v:0 \
  -map 0:a:0? \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=nv12,hwupload" \
  -c:v h264_vaapi \
  -b:v 4000k \
  -maxrate 4000k \
  -bufsize 8000k \
  -g 60 \
  -c:a aac \
  -b:a 192k \
  -ar 48000 \
  -ac 2 \
  -movflags +faststart \
  "$OUTFILE" >> "$LOG_FILE" 2>&1

else
  ffmpeg -y -hide_banner \
  -i "$INPUT_FILE" \
  -map 0:v:0 \
  -map 0:a:0? \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=yuv420p" \
  -c:v libx264 \
  -preset veryfast \
  -b:v 4000k \
  -maxrate 4000k \
  -bufsize 8000k \
  -g 60 \
  -c:a aac \
  -b:a 192k \
  -ar 48000 \
  -ac 2 \
  -movflags +faststart \
  "$OUTFILE" >> "$LOG_FILE" 2>&1
fi

RESULT=$?

if [ "$RESULT" -eq 0 ]; then
  mv "$INPUT_FILE" "$PROCESSED/$BASENAME"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] SUCCESS: $INPUT_FILE" >> "$LOG_FILE"
else
  mv "$INPUT_FILE" "$FAILED/$BASENAME"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED: $INPUT_FILE" >> "$LOG_FILE"
fi

/opt/custom-streaming/scripts/generate_human_playlist.sh "$CHANNEL_DIR"
/opt/custom-streaming/scripts/generate_playlist.sh "$CHANNEL_DIR"

exit "$RESULT"
