#!/bin/bash

CHANNEL_DIR="$1"

if [ -z "$CHANNEL_DIR" ]; then
  echo "Usage: generate_playlist.sh <channel_dir>"
  exit 1
fi

CONFIG="$CHANNEL_DIR/channel.json"

HUMAN_PLAYLIST="$CHANNEL_DIR/$(jq -r '.files.human_playlist // "playlists/human_playlist.json"' "$CONFIG")"
FFMPEG_PLAYLIST="$CHANNEL_DIR/$(jq -r '.files.ffmpeg_playlist // "playlists/ffmpeg_playlist.txt"' "$CONFIG")"

mkdir -p "$(dirname "$FFMPEG_PLAYLIST")"

if [ ! -f "$HUMAN_PLAYLIST" ]; then
  echo "Human playlist missing: $HUMAN_PLAYLIST"
  : > "$FFMPEG_PLAYLIST"
  exit 0
fi

jq -r '
  sort_by(.order)
  | .[]
  | select(.enabled == true)
  | select(.video_source_id == null or .video_source_id == "file")
  | select(.file != null and .file != "")
  | "file '\''" + .file + "'\''"
' "$HUMAN_PLAYLIST" > "$FFMPEG_PLAYLIST"

echo "Generated FFmpeg playlist:"
cat "$FFMPEG_PLAYLIST"
