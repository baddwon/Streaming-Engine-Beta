#!/bin/bash
set -e

CHANNEL_DIR="$1"

python3 - "$CHANNEL_DIR" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

channel_dir = Path(sys.argv[1])
config_path = channel_dir / "channel.json"

with config_path.open("r", encoding="utf-8") as f:
    cfg = json.load(f)

production = channel_dir / cfg.get("paths", {}).get("production", "production")
playlist_json = channel_dir / cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
playlist_json.parent.mkdir(parents=True, exist_ok=True)

old_playlist = []
if playlist_json.exists():
    try:
        old_playlist = json.loads(playlist_json.read_text(encoding="utf-8"))
        if not isinstance(old_playlist, list):
            old_playlist = []
    except Exception:
        old_playlist = []

old_by_file = {
    str(item.get("file")): item
    for item in old_playlist
    if item.get("file")
}

production_files = sorted(
    [p for p in production.glob("*.mp4") if p.is_file()],
    key=lambda p: p.name.lower()
)
production_file_set = {str(p) for p in production_files}

ordered_files = []

# Preserve existing human playlist order for files that still exist.
for item in sorted(old_playlist, key=lambda x: x.get("order", 999999)):
    file_path = str(item.get("file", ""))
    if file_path in production_file_set and file_path not in ordered_files:
        ordered_files.append(file_path)

# Append new production files that are not already in the saved playlist.
for path in production_files:
    file_path = str(path)
    if file_path not in ordered_files:
        ordered_files.append(file_path)

def duration_seconds(file_path: str) -> float:
    try:
        out = subprocess.check_output(
            [
                "ffprobe",
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                file_path,
            ],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        return float(out or 0)
    except Exception:
        return 0.0

new_playlist = []
for idx, file_path in enumerate(ordered_files, start=1):
    old = old_by_file.get(file_path, {})
    title = old.get("title") or Path(file_path).stem

    new_playlist.append({
        "order": idx,
        "enabled": bool(old.get("enabled", False)),
        "title": title,
        "file": file_path,
        "duration_seconds": duration_seconds(file_path),
        "audio_source_id": old.get("audio_source_id", "embedded"),
        "video_source_id": old.get("video_source_id", "file"),
    })

playlist_json.write_text(json.dumps(new_playlist, indent=2), encoding="utf-8")

print("Generated human playlist:")
print(json.dumps(new_playlist, indent=2))
PY
