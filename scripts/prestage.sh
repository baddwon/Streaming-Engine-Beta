#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CHANNEL_DIR="$1"
INPUT_FILE="$2"

if [ -f "$SCRIPT_DIR/detect_system.sh" ]; then
  . "$SCRIPT_DIR/detect_system.sh" >/dev/null 2>&1 || true
fi

if [ -f /tmp/custom-streaming-encoder.env ]; then
  . /tmp/custom-streaming-encoder.env
fi

VIDEO_ENCODER="${VIDEO_ENCODER:-x264}"
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"

if [ -z "$CHANNEL_DIR" ] || [ -z "$INPUT_FILE" ]; then
  echo "Usage: prestage.sh <channel_dir> <input_file>"
  exit 1
fi

CONFIG="$CHANNEL_DIR/channel.json"

CHANNEL_ENCODER_REQUESTED="$(jq -r '.video_encoder_requested // empty' "$CONFIG" 2>/dev/null)"
if [ -n "$CHANNEL_ENCODER_REQUESTED" ]; then
  export VIDEO_ENCODER_REQUESTED="$CHANNEL_ENCODER_REQUESTED"
fi

if [ -f "$SCRIPT_DIR/detect_system.sh" ]; then
  . "$SCRIPT_DIR/detect_system.sh" >/dev/null 2>&1 || true
fi

if [ -f /tmp/custom-streaming-encoder.env ]; then
  . /tmp/custom-streaming-encoder.env
fi
CHANNELS_ROOT="${CHANNEL_ROOT:-$(dirname "$CHANNEL_DIR")}"
SETTINGS="${STREAMING_ENGINE_CONFIG:-${CHANNELS_ROOT}/system/settings.json}"

NORMALIZE_AUDIO=$(jq -r '.normalize_embedded_audio // true' "$SETTINGS" 2>/dev/null)
TARGET_LUFS=$(jq -r '.target_lufs // -16' "$SETTINGS" 2>/dev/null)
TRUE_PEAK=$(jq -r '.true_peak // -1.5' "$SETTINGS" 2>/dev/null)
LOUDNESS_RANGE=$(jq -r '.loudness_range // 11' "$SETTINGS" 2>/dev/null)

TARGET_LUFS="${TARGET_LUFS:--16}"
TRUE_PEAK="${TRUE_PEAK:--1.5}"
LOUDNESS_RANGE="${LOUDNESS_RANGE:-11}"

if [ "$NORMALIZE_AUDIO" = "true" ]; then
  AUDIO_FILTER="loudnorm=I=${TARGET_LUFS}:TP=${TRUE_PEAK}:LRA=${LOUDNESS_RANGE}"
else
  AUDIO_FILTER="anull"
fi

INCOMING="$CHANNEL_DIR/$(jq -r '.paths.incoming // "incoming"' "$CONFIG")"
PRODUCTION="$CHANNEL_DIR/$(jq -r '.paths.production // "production"' "$CONFIG")"
PROCESSED="$CHANNEL_DIR/$(jq -r '.paths.processed // "processed"' "$CONFIG")"
FAILED="$CHANNEL_DIR/$(jq -r '.paths.failed // "failed"' "$CONFIG")"
LOG_DIR="$CHANNEL_DIR/$(jq -r '.paths.logs // "runtime/logs"' "$CONFIG")"

mkdir -p "$INCOMING" "$PRODUCTION" "$PROCESSED" "$FAILED" "$LOG_DIR"

LOG_FILE="$LOG_DIR/prestage-watch.log"

BASENAME="$(basename "$INPUT_FILE")"
NAME_NO_EXT="${BASENAME%.*}"

LOCK_DIR="$CHANNEL_DIR/runtime/locks"
CACHE_DIR="$CHANNEL_DIR/runtime/cache"
mkdir -p "$LOCK_DIR" "$CACHE_DIR"
LOCK_FILE="$LOCK_DIR/prestage-numbering.lock"
SEQUENCE_FILE="$CACHE_DIR/prestage_sequence.txt"

exec 9>"$LOCK_FILE"
flock -x 9

MAX_PREFIX="$(find "$PRODUCTION" -maxdepth 1 -type f -iname "*.mp4" -printf "%f\n" 2>/dev/null \
  | sed -n 's/^\([0-9][0-9][0-9]\)[_-].*/\1/p' \
  | sort -n \
  | tail -1)"

if [ -z "$MAX_PREFIX" ]; then
  MAX_PREFIX=0
fi

LAST_USED=0
if [ -f "$SEQUENCE_FILE" ]; then
  LAST_USED="$(cat "$SEQUENCE_FILE" 2>/dev/null | tr -cd '0-9')"
  LAST_USED="${LAST_USED:-0}"
fi

if [ "$LAST_USED" -lt "$((10#$MAX_PREFIX))" ]; then
  LAST_USED="$((10#$MAX_PREFIX))"
fi

NEXT=$((LAST_USED + 1))
OUTFILE="$PRODUCTION/$(printf "%03d" "$NEXT")_${NAME_NO_EXT}.mp4"

while [ -e "$OUTFILE" ]; do
  NEXT=$((NEXT + 1))
  OUTFILE="$PRODUCTION/$(printf "%03d" "$NEXT")_${NAME_NO_EXT}.mp4"
done

echo "$NEXT" > "$SEQUENCE_FILE"
flock -u 9

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
  -af "$AUDIO_FILTER" \
  -c:a aac \
  -b:a 192k \
  -ar 48000 \
  -ac 2 \
  -movflags +faststart \
  "$OUTFILE" >> "$LOG_FILE" 2>&1

elif [ "$VIDEO_ENCODER" = "vaapi" ]; then
  ffmpeg -y -hide_banner \
  -vaapi_device "$VAAPI_DEVICE" \
  -i "$INPUT_FILE" \
  -map 0:v:0 \
  -map 0:a:0? \
  -vf "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,fps=30,format=nv12,hwupload" \
  -c:v h264_vaapi \
  -b:v 4000k \
  -maxrate 4000k \
  -bufsize 8000k \
  -g 60 \
  -af "$AUDIO_FILTER" \
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
  -af "$AUDIO_FILTER" \
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

"$SCRIPT_DIR/generate_human_playlist.sh" "$CHANNEL_DIR"
"$SCRIPT_DIR/generate_playlist.sh" "$CHANNEL_DIR"

exit "$RESULT"
