#!/bin/bash

CHANNEL_DIR="$1"

CONFIG="$CHANNEL_DIR/channel.json"

LOG_DIR="$CHANNEL_DIR/$(jq -r '.paths.logs // "runtime/logs"' "$CONFIG")"

mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/output-monitor.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting output monitor for $CHANNEL_DIR" >> "$LOG_FILE"

while true; do

  OUTPUTS_DIR="$CHANNEL_DIR/outputs"

  for OUTPUT_CONFIG in "$OUTPUTS_DIR"/*.json; do

    [ -f "$OUTPUT_CONFIG" ] || continue

    OUTPUT_ID=$(jq -r '.output_id' "$OUTPUT_CONFIG")

    PID_FILE="$CHANNEL_DIR/runtime/pids/${OUTPUT_ID}.pid"

    if [ ! -f "$PID_FILE" ]; then
      continue
    fi

    PID=$(cat "$PID_FILE")

    if ! ps -p "$PID" > /dev/null 2>&1; then

      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Output down: $OUTPUT_ID. Restarting." >> "$LOG_FILE"

      /opt/custom-streaming/scripts/start_output.sh \
        "$CHANNEL_DIR" \
        "$OUTPUT_ID" >> "$LOG_FILE" 2>&1
    fi

  done

  sleep 15

done
