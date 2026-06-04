#!/bin/bash

echo "[INIT] Starting Custom Streaming Engine"
/opt/custom-streaming/scripts/detect_system.sh
. /tmp/custom-streaming-encoder.env

mkdir -p /var/www/html/hls

echo "[INIT] Starting nginx"
service nginx start

echo "[INIT] Testing nginx config"
nginx -t

echo "[INIT] Starting Flask web UI"
cd /opt/custom-streaming/web
nohup python3 app.py > /var/log/custom-streaming-web.log 2>&1 &

CHANNEL_BASE="/channels"

for CHANNEL_DIR in "$CHANNEL_BASE"/*; do

  [ -d "$CHANNEL_DIR" ] || continue

  CHANNEL_CONFIG="$CHANNEL_DIR/channel.json"

  [ -f "$CHANNEL_CONFIG" ] || continue

  AUTO_START_CHANNEL=$(jq -r '.startup.auto_start_channel // true' "$CHANNEL_CONFIG")
  AUTO_START_WATCHERS=$(jq -r '.startup.auto_start_watchers // true' "$CHANNEL_CONFIG")
  AUTO_START_OUTPUTS=$(jq -r '.startup.auto_start_outputs // true' "$CHANNEL_CONFIG")

  if [ "$AUTO_START_CHANNEL" != "true" ]; then
    echo "[INIT] Skipping channel: $CHANNEL_DIR"
    continue
  fi

  echo "[INIT] Initializing channel: $CHANNEL_DIR"

  mkdir -p \
    "$CHANNEL_DIR/incoming" \
    "$CHANNEL_DIR/production" \
    "$CHANNEL_DIR/processed" \
    "$CHANNEL_DIR/failed" \
    "$CHANNEL_DIR/playlists" \
    "$CHANNEL_DIR/runtime/logs" \
    "$CHANNEL_DIR/runtime/pids" \
    "$CHANNEL_DIR/runtime/status" \
    "$CHANNEL_DIR/runtime/cache"

  echo "[INIT] Cleaning stale runtime state"
  rm -f "$CHANNEL_DIR/runtime/pids/"*
  rm -f "$CHANNEL_DIR/runtime/status/"*

  echo "[INIT] Generating playlists"
  /opt/custom-streaming/scripts/generate_human_playlist.sh "$CHANNEL_DIR"
  /opt/custom-streaming/scripts/generate_playlist.sh "$CHANNEL_DIR"

  if [ "$AUTO_START_WATCHERS" = "true" ]; then
    echo "[INIT] Starting watcher and monitor"

    nohup /opt/custom-streaming/scripts/watch_prestage.sh \
      "$CHANNEL_DIR" \
      > /dev/null 2>&1 &

    nohup /opt/custom-streaming/scripts/monitor_outputs.sh \
      "$CHANNEL_DIR" \
      > /dev/null 2>&1 &
  fi

  if [ "$AUTO_START_OUTPUTS" = "true" ]; then

    OUTPUTS_DIR="$CHANNEL_DIR/outputs"

    for OUTPUT_CONFIG in "$OUTPUTS_DIR"/*.json; do

      [ -f "$OUTPUT_CONFIG" ] || continue

      OUTPUT_ID=$(jq -r '.output_id' "$OUTPUT_CONFIG")
      ENABLED=$(jq -r '.enabled // true' "$OUTPUT_CONFIG")
      AUTO_START=$(jq -r '.auto_start // true' "$OUTPUT_CONFIG")
      PLAYLIST_REL=$(jq -r '.playlist // "playlists/ffmpeg_playlist.txt"' "$OUTPUT_CONFIG")
      PLAYLIST_FILE="$CHANNEL_DIR/$PLAYLIST_REL"

      if [ "$ENABLED" = "true" ] && [ "$AUTO_START" = "true" ]; then

        if [ ! -s "$PLAYLIST_FILE" ]; then
          echo "[INIT] Not starting $OUTPUT_ID because playlist is empty: $PLAYLIST_FILE"
          continue
        fi

        HLS_DIR=$(jq -r '.hls.output_dir // empty' "$OUTPUT_CONFIG")

        if [ -n "$HLS_DIR" ]; then
          echo "[INIT] Cleaning HLS dir: $HLS_DIR"
          mkdir -p "$HLS_DIR"
          rm -f "$HLS_DIR"/*
        fi

        echo "[INIT] Auto-starting output: $OUTPUT_ID"

        /opt/custom-streaming/scripts/start_output.sh \
          "$CHANNEL_DIR" \
          "$OUTPUT_ID"
      fi
    done
  fi
done

echo "[INIT] Custom Streaming Engine ready"

tail -f /dev/null
