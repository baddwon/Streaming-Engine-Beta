#!/bin/bash

CHANNEL_DIR="$1"
CONFIG="$CHANNEL_DIR/channel.json"

PRODUCTION="$CHANNEL_DIR/$(jq -r '.paths.production // "production"' "$CONFIG")"
PLAYLIST_JSON="$CHANNEL_DIR/$(jq -r '.files.human_playlist // "playlists/human_playlist.json"' "$CONFIG")"

mkdir -p "$(dirname "$PLAYLIST_JSON")"

TMP=$(mktemp)
jq -n '[]' > "$TMP"

COUNT=1

find "$PRODUCTION" -maxdepth 1 -type f -iname "*.mp4" | sort | while read -r FILE; do
  BASENAME=$(basename "$FILE")
  TITLE="${BASENAME%.*}"

  EXISTING=$(jq --arg file "$FILE" '.[] | select(.file == $file)' "$PLAYLIST_JSON" 2>/dev/null)

  if [ -n "$EXISTING" ]; then
    ENABLED=$(echo "$EXISTING" | jq -r '.enabled // false')
    SAVED_TITLE=$(echo "$EXISTING" | jq -r '.title // empty')
    AUDIO_SOURCE_ID=$(echo "$EXISTING" | jq -r '.audio_source_id // "embedded"')
    VIDEO_SOURCE_ID=$(echo "$EXISTING" | jq -r '.video_source_id // "file"')

    if [ -n "$SAVED_TITLE" ]; then
      TITLE="$SAVED_TITLE"
    fi
  else
    ENABLED=false
    AUDIO_SOURCE_ID="embedded"
    VIDEO_SOURCE_ID="file"
  fi

  DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$FILE" 2>/dev/null)
  DURATION=${DURATION:-0}

  jq \
    --argjson order "$COUNT" \
    --argjson enabled "$ENABLED" \
    --arg title "$TITLE" \
    --arg file "$FILE" \
    --argjson duration "$DURATION" \
    --arg audio_source_id "$AUDIO_SOURCE_ID" \
    --arg video_source_id "$VIDEO_SOURCE_ID" \
    '. += [{
      order: $order,
      enabled: $enabled,
      title: $title,
      file: $file,
      duration_seconds: $duration,
      audio_source_id: $audio_source_id,
      video_source_id: $video_source_id
    }]' "$TMP" > "$TMP.new"

  mv "$TMP.new" "$TMP"
  COUNT=$((COUNT + 1))
done

mv "$TMP" "$PLAYLIST_JSON"

echo "Generated human playlist:"
cat "$PLAYLIST_JSON"
