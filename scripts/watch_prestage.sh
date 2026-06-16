#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

    "$SCRIPT_DIR/prestage.sh" "$CHANNEL_DIR" "$FILE"

    "$SCRIPT_DIR/generate_human_playlist.sh" "$CHANNEL_DIR"
    "$SCRIPT_DIR/generate_playlist.sh" "$CHANNEL_DIR"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Import complete. Live output NOT restarted. Apply Playlist Changes to put enabled items on air." >> "$LOG_FILE"

  done

  sleep 5

done
