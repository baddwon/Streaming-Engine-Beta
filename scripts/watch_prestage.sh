#!/bin/bash

CHANNEL_DIR="$1"

if [ -z "$CHANNEL_DIR" ]; then
  echo "Usage: watch_prestage.sh <channel_dir>"
  exit 1
fi

CONFIG="$CHANNEL_DIR/channel.json"

INCOMING="$CHANNEL_DIR/$(jq -r '.paths.incoming // "incoming"' "$CONFIG")"
LOG_DIR="$CHANNEL_DIR/$(jq -r '.paths.logs // "runtime/logs"' "$CONFIG")"

mkdir -p "$INCOMING" "$LOG_DIR"

LOG_FILE="$LOG_DIR/prestage-watch.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] watch_prestage started" >> "$LOG_FILE"

while true; do

  for FILE in "$INCOMING"/*; do

    if [ ! -f "$FILE" ]; then
      continue
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Incoming media detected: $FILE" >> "$LOG_FILE"

    /opt/custom-streaming/scripts/prestage.sh "$CHANNEL_DIR" "$FILE"

    /opt/custom-streaming/scripts/generate_human_playlist.sh "$CHANNEL_DIR"
    /opt/custom-streaming/scripts/generate_playlist.sh "$CHANNEL_DIR"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Import complete. Live output NOT restarted. Apply Playlist Changes to put enabled items on air." >> "$LOG_FILE"

  done

  sleep 5

done
