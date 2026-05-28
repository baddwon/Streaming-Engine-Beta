#!/bin/bash

CHANNEL_DIR="$1"
OUTPUT_ID="$2"

PID_DIR="$CHANNEL_DIR/runtime/pids"
STATUS_FILE="$CHANNEL_DIR/runtime/status/${OUTPUT_ID}.json"
LOG_FILE="$CHANNEL_DIR/runtime/logs/${OUTPUT_ID}.log"

for f in \
  "$PID_DIR/${OUTPUT_ID}.pid" \
  "$PID_DIR/${OUTPUT_ID}.hls.pid" \
  "$PID_DIR/${OUTPUT_ID}.video.pid" \
  "$PID_DIR/${OUTPUT_ID}.audio.pid"
do
  if [ -f "$f" ]; then
    PID=$(cat "$f")
    kill "$PID" 2>/dev/null || true
    sleep 1
    kill -9 "$PID" 2>/dev/null || true
    rm -f "$f"
  fi
done

pkill -9 -f "broadcast_playout.sh $CHANNEL_DIR $OUTPUT_ID" || true
pkill -9 -f "ffmpeg.*video.ts" || true
pkill -9 -f "ffmpeg.*audio.ts" || true
pkill -9 -f "ffmpeg.*stream.m3u8" || true

cat > "$STATUS_FILE" <<JSON
{
  "output_id": "$OUTPUT_ID",
  "status": "stopped",
  "stopped_at": "$(date --iso-8601=seconds)"
}
JSON

echo "Stopped output $OUTPUT_ID" | tee -a "$LOG_FILE"
