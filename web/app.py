# BOOTSTRAP CHANNEL ROOT - simple-portable
from pathlib import Path
import os

CHANNEL_ROOT = Path(os.getenv("CHANNEL_ROOT", "/channels"))
CHANNEL_ROOT.mkdir(parents=True, exist_ok=True)
from flask import Flask, render_template, redirect, request, jsonify
from werkzeug.utils import secure_filename
import json
import os
import subprocess
import time
from datetime import datetime, timezone

app = Flask(__name__)
CHANNELS_BASE = os.environ.get("CHANNEL_ROOT", "/channels")
SETTINGS_PATH = os.environ.get("STREAMING_ENGINE_CONFIG", os.path.join(CHANNELS_BASE, "system", "settings.json"))
SCRIPT_DIR = os.environ.get("STREAMING_ENGINE_SCRIPTS", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts"))

def script_path(name):
    return os.path.join(SCRIPT_DIR, name)

DEFAULT_SETTINGS = {
    "web_port": 5000,
    "hls_port": int(os.environ.get("HLS_PUBLIC_PORT", "8088")),
    "default_encoder": os.environ.get("VIDEO_ENCODER", "auto"),
    "default_video_bitrate": 4000,
    "default_audio_bitrate": 128,
    "default_hls_time": 4,
    "default_hls_list_size": 24,
    "normalize_embedded_audio": True,
    "target_lufs": -16,
    "true_peak": -1.5,
    "loudness_range": 11,
    "output_gain_db": 0,
    "limiter_limit": 0.90,
    "audio_sources": [
        {"id": "embedded", "friendly_name": "Embedded File Audio", "type": "embedded", "url": ""},
        {"id": "silent", "friendly_name": "Silent / No Audio", "type": "silent", "url": ""}
    ],
    "network_policy": {
        "mode": "preview",
        "timezone": "America/Chicago",
        "ntp_server": "pool.ntp.org",
        "auto_allow_lan": True,
        "manual_allowed_subnets": ["192.168.1.0/24", "192.168.66.0/24", "10.10.10.0/24"],
        "allow_web_ui_from_lan": True,
        "allow_hls_from_lan": True,
        "allow_vnc_from_lan": False,
        "allow_public_access": False,
        "allow_dns": True,
        "allow_ntp": True,
        "allow_configured_audio_sources": True,
        "allow_configured_outputs": True,
        "allow_multicast_when_configured": True,
        "maintenance_mode": False,
        "maintenance_timeout_minutes": 30
    }
}

def load_settings():
    settings = DEFAULT_SETTINGS.copy()
    try:
        existing = load_json(SETTINGS_PATH, {})
        if existing:
            settings.update(existing)
    except Exception:
        pass
    return settings

def save_settings(settings):
    os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
    save_json(SETTINGS_PATH, settings)


def get_audio_sources():
    settings = load_settings()
    sources = settings.get("audio_sources", [])

    by_id = {}
    for source in sources:
        sid = source.get("id")
        if sid:
            by_id[sid] = source

    by_id.setdefault("embedded", {"id": "embedded", "friendly_name": "Embedded File Audio", "type": "embedded", "url": ""})
    by_id.setdefault("silent", {"id": "silent", "friendly_name": "Silent / No Audio", "type": "silent", "url": ""})

    ordered = [by_id["embedded"], by_id["silent"]]
    ordered += [v for k, v in by_id.items() if k not in ["embedded", "silent"]]
    return ordered



def load_json(path, default=None):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def channel_dir(channel):
    return os.path.join(CHANNELS_BASE, channel)


def restart_output(cdir, output_id="hls-main"):
    subprocess.run([script_path("stop_output.sh"), cdir, output_id])
    subprocess.run(["bash", "-c", "rm -f /var/www/html/hls/channel1/*"])
    subprocess.run(["bash", "-c", f"rm -f {cdir}/runtime/pids/*"])
    subprocess.run(["bash", "-c", f"rm -f {cdir}/runtime/status/*"])
    subprocess.run([script_path("start_output.sh"), cdir, output_id])


def tail_file(path, lines=40):
    try:
        with open(path, "r", errors="ignore") as f:
            return f.readlines()[-lines:]
    except Exception:
        return []


def get_stream_url(channel, output, request_host):
    if not output.get("hls"):
        return None

    output_file = output["hls"].get("output_file", "stream.m3u8")
    output_dir = output["hls"].get("output_dir", "")

    if output_dir.startswith("/var/www/html"):
        public_path = output_dir.replace("/var/www/html", "")
    else:
        public_path = f"/hls/{channel.lower()}"

    hls_public_port = str(load_settings().get("hls_port", os.environ.get("HLS_PUBLIC_PORT", "8088")))
    return f"http://{request_host}:{hls_public_port}{public_path}/{output_file}"


def parse_iso(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except Exception:
        return None


def load_channel_data(channel):
    cdir = channel_dir(channel)
    cfg = load_json(os.path.join(cdir, "channel.json"), {})

    playlist_path = os.path.join(
        cdir,
        cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
    )

    playlist = load_json(playlist_path, [])

    for item in playlist:
        full_path = item.get("file", "")
        item["filename"] = os.path.basename(full_path)
        item["full_path"] = full_path
        item.setdefault("audio_source_id", "embedded")
        item.setdefault("video_source_id", "file")

    cfg.setdefault("audio_sources", [
        {"id": "embedded", "friendly_name": "Embedded File Audio", "type": "embedded", "url": ""},
        {"id": "silent", "friendly_name": "Silent / No Audio", "type": "silent", "url": ""}
    ])

    cfg.setdefault("video_sources", [
        {"id": "file", "friendly_name": "Playlist File Video", "type": "file", "url": ""}
    ])

    return cdir, cfg, playlist


def load_outputs(channel, cdir, cfg):
    outputs = []
    primary_stream_url = None
    request_host = request.host.split(":")[0]

    outdir = os.path.join(cdir, cfg.get("paths", {}).get("outputs", "outputs"))

    if os.path.isdir(outdir):
        for f in sorted(os.listdir(outdir)):
            if not f.endswith(".json"):
                continue

            output = load_json(os.path.join(outdir, f), {})
            output_id = output.get("output_id")

            status_path = os.path.join(cdir, "runtime", "status", f"{output_id}.json")
            output["status"] = load_json(status_path, {"status": "unknown"})

            if output.get("type") == "hls" and output.get("hls"):
                actual_url = get_stream_url(channel, output, request_host)
                output["hls"]["actual_public_url"] = actual_url
                if primary_stream_url is None:
                    primary_stream_url = actual_url

            outputs.append(output)

    return outputs, primary_stream_url


def estimate_current_item(playlist, outputs):
    running_output = None

    for output in outputs:
        status = output.get("status", {})
        if status.get("status") == "running" and status.get("started_at"):
            running_output = output
            break

    if not running_output:
        return None

    started_at = parse_iso(running_output["status"].get("started_at"))
    if not started_at:
        return None

    if started_at.tzinfo is None:
        started_at = started_at.replace(tzinfo=timezone.utc)

    now = datetime.now(timezone.utc)
    elapsed = max(0, (now - started_at).total_seconds())

    enabled_items = [
        item for item in sorted(playlist, key=lambda x: x.get("order", 0))
        if item.get("enabled", True)
    ]

    total_duration = sum(float(item.get("duration_seconds", 0) or 0) for item in enabled_items)

    if total_duration <= 0:
        return None

    position = elapsed % total_duration
    running_total = 0

    for item in enabled_items:
        duration = float(item.get("duration_seconds", 0) or 0)
        running_total += duration

        if position <= running_total:
            item_copy = dict(item)
            item_copy["elapsed_in_item"] = max(0, duration - (running_total - position))
            item_copy["duration_seconds"] = duration
            item_copy["playlist_position_seconds"] = position
            return item_copy

    return None


def get_folder_files(path):
    if not os.path.isdir(path):
        return []

    files = []
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        if os.path.isfile(full):
            files.append({
                "name": name,
                "path": full,
                "size": os.path.getsize(full)
            })
    return files


def load_ingest_status(cdir, cfg):
    incoming = os.path.join(cdir, cfg.get("paths", {}).get("incoming", "incoming"))
    processed = os.path.join(cdir, cfg.get("paths", {}).get("processed", "processed"))
    failed = os.path.join(cdir, cfg.get("paths", {}).get("failed", "failed"))
    log_path = os.path.join(cdir, cfg.get("paths", {}).get("logs", "runtime/logs"), "prestage-watch.log")

    return {
        "incoming": get_folder_files(incoming),
        "processed": get_folder_files(processed)[-10:],
        "failed": get_folder_files(failed)[-10:],
        "log_tail": "".join(tail_file(log_path, 35))
    }


def get_channel_summary(channel_id, cdir, cfg):
    playlist_path = os.path.join(
        cdir,
        cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
    )

    playlist = load_json(playlist_path, [])
    outputs, primary_stream_url = load_outputs(channel_id, cdir, cfg)

    running = False
    encoder = ""
    audio_source = ""
    started_at = ""
    pid = ""

    for output in outputs:
        status = output.get("status", {})
        if status.get("status") == "running":
            running = True
            encoder = status.get("video_encoder", "")
            audio_source = status.get("audio_source_id", "")
            started_at = status.get("started_at", "")
            pid = status.get("pid", "")
            break

    return {
        "playlist_count": len(playlist),
        "enabled_count": len([x for x in playlist if x.get("enabled")]),
        "running": running,
        "encoder": encoder,
        "audio_source": audio_source,
        "started_at": started_at,
        "pid": pid,
        "primary_stream_url": primary_stream_url
    }

@app.route("/")
def index():
    channels = []

    for name in sorted(os.listdir(CHANNELS_BASE)):
        cdir = os.path.join(CHANNELS_BASE, name)
        if not os.path.isdir(cdir):
            continue

        cfg = load_json(os.path.join(cdir, "channel.json"))

        if cfg:
            channels.append({"dir": cdir, "name": name, "config": cfg, "summary": get_channel_summary(name, cdir, cfg)})

    return render_template("index.html", channels=channels)


@app.route("/channel/<channel>")
def channel(channel):
    cdir, cfg, playlist = load_channel_data(channel)
    outputs, primary_stream_url = load_outputs(channel, cdir, cfg)
    current_item = estimate_current_item(playlist, outputs)
    ingest = load_ingest_status(cdir, cfg)

    return render_template(
        "channel.html",
        channel=channel,
        cfg=cfg,
        playlist=playlist,
        outputs=outputs,
        primary_stream_url=primary_stream_url,
        current_item=current_item,
        ingest=ingest,
        audio_sources=get_audio_sources(),
        video_sources=cfg.get("video_sources", []),
        active_audio_source_id=cfg.get("active_audio_source_id", "embedded"),
        video_encoder_requested=cfg.get("video_encoder_requested", "auto")
    )


@app.route("/api/channel/<channel>/status")
def api_channel_status(channel):
    cdir, cfg, playlist = load_channel_data(channel)
    outputs, primary_stream_url = load_outputs(channel, cdir, cfg)
    current_item = estimate_current_item(playlist, outputs)
    ingest = load_ingest_status(cdir, cfg)

    return jsonify({
        "channel": channel,
        "friendly_name": cfg.get("name", channel),
        "playlist_count": len(playlist),
        "playlist_files": [item.get("filename") for item in playlist],
        "primary_stream_url": primary_stream_url,
        "outputs": outputs,
        "current_item": current_item,
        "ingest": ingest
    })



@app.route("/channel/<channel>/audio/select", methods=["POST"])
def select_channel_audio(channel):
    cdir = channel_dir(channel)
    cfg_path = os.path.join(cdir, "channel.json")
    cfg = load_json(cfg_path, {})

    source_id = request.form.get("active_audio_source_id", "embedded").strip()
    valid_ids = [s.get("id") for s in get_audio_sources()]

    if source_id not in valid_ids:
        source_id = "embedded"

    cfg["active_audio_source_id"] = source_id
    save_json(cfg_path, cfg)

    # Apply immediately by restarting HLS output.
    try:
        subprocess.run(
            [script_path("stop_output.sh"), cdir, "hls-main"],
            timeout=10
        )

        subprocess.Popen(
            [script_path("start_output.sh"), cdir, "hls-main"]
        )

        status_path = os.path.join(cdir, "runtime", "status", "hls-main.json")
        stream_path = os.path.join(os.environ.get("HLS_ROOT", "/var/www/html/hls"), "Ch_" + channel, "stream.m3u8")

        for _ in range(20):
            status = load_json(status_path, {})
            if (
                status.get("status") == "running"
                and status.get("audio_source_id") == source_id
                and os.path.exists(stream_path)
                and os.path.getsize(stream_path) > 100
            ):
                break
            time.sleep(0.5)

    except Exception as e:
        print(f"Audio output restart failed: {e}")

    return redirect(f"/channel/{channel}")
@app.route("/engineer/audio-source/add", methods=["POST"])
def add_audio_source():
    settings = load_settings()

    source_id = request.form.get("source_id", "").strip()
    friendly_name = request.form.get("friendly_name", "").strip()
    source_type = request.form.get("source_type", "web").strip()
    url = request.form.get("url", "").strip()

    import re
    source_id = re.sub(r"[^A-Za-z0-9_-]", "", source_id.replace(" ", "_"))

    if not source_id:
        return redirect("/engineer?tab=audio")

    if source_id in ["embedded", "silent"]:
        return redirect("/engineer?tab=audio")

    if not friendly_name:
        friendly_name = source_id

    settings.setdefault("audio_sources", get_audio_sources())
    settings["audio_sources"] = [s for s in settings["audio_sources"] if s.get("id") != source_id]

    settings["audio_sources"].append({
        "id": source_id,
        "friendly_name": friendly_name,
        "type": source_type,
        "url": url
    })

    save_settings(settings)
    return redirect("/engineer?tab=audio")

@app.route("/engineer/audio-source/delete", methods=["POST"])
def delete_audio_source():
    settings = load_settings()

    source_id = request.form.get("source_id", "").strip()

    if source_id in ["embedded", "silent"]:
        return redirect("/engineer?tab=audio")

    settings.setdefault("audio_sources", get_audio_sources())
    settings["audio_sources"] = [s for s in settings["audio_sources"] if s.get("id") != source_id]
    save_settings(settings)

    # Any channel using the deleted source falls back to embedded.
    base = Path(CHANNELS_BASE)
    if base.exists():
        for item in base.iterdir():
            if not item.is_dir() or item.name == "system":
                continue

            cfg_path = item / "channel.json"
            cfg = load_json(str(cfg_path), {})
            if cfg.get("active_audio_source_id") == source_id:
                cfg["active_audio_source_id"] = "embedded"
                save_json(str(cfg_path), cfg)

            playlist_path = item / cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
            playlist = load_json(str(playlist_path), [])
            changed = False
            for row in playlist:
                if row.get("audio_source_id") == source_id:
                    row["audio_source_id"] = "embedded"
                    changed = True
            if changed:
                save_json(str(playlist_path), playlist)

    return redirect("/engineer?tab=audio")


@app.route("/channel/<channel>/upload", methods=["POST"])
def upload_file(channel):
    cdir = channel_dir(channel)
    cfg = load_json(os.path.join(cdir, "channel.json"), {})

    incoming_dir = os.path.join(cdir, cfg.get("paths", {}).get("incoming", "incoming"))
    os.makedirs(incoming_dir, exist_ok=True)

    files = request.files.getlist("media")

    for file in files:
        if not file or file.filename == "":
            continue

        filename = secure_filename(file.filename)
        if not filename:
            continue

        dest = os.path.join(incoming_dir, filename)
        base, ext = os.path.splitext(dest)
        counter = 1

        while os.path.exists(dest):
            dest = f"{base}_{counter}{ext}"
            counter += 1

        file.save(dest)

        # Direct ingest trigger. This makes uploads work even when the
        # background watcher was not running because the channel was created
        # after container startup.
        subprocess.Popen([
            script_path("prestage.sh"),
            cdir,
            dest
        ])
    return redirect(f"/channel/{channel}")


@app.route("/channel/<channel>/content/delete", methods=["POST"])
def delete_content(channel):
    cdir = channel_dir(channel)
    cfg = load_json(os.path.join(cdir, "channel.json"), {})

    target = request.form.get("file")

    if not target:
        return redirect(f"/channel/{channel}")

    allowed_roots = [
        os.path.realpath(os.path.join(cdir, cfg.get("paths", {}).get("production", "production"))),
        os.path.realpath(os.path.join(cdir, cfg.get("paths", {}).get("processed", "processed"))),
        os.path.realpath(os.path.join(cdir, cfg.get("paths", {}).get("failed", "failed"))),
        os.path.realpath(os.path.join(cdir, cfg.get("paths", {}).get("incoming", "incoming")))
    ]

    real_target = os.path.realpath(target)

    if not any(real_target.startswith(root + os.sep) or real_target == root for root in allowed_roots):
        return "Refusing to delete file outside channel media folders", 400

    if os.path.exists(real_target) and os.path.isfile(real_target):
        os.remove(real_target)

    playlist_path = os.path.join(
        cdir,
        cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
    )

    playlist = load_json(playlist_path, [])
    playlist = [item for item in playlist if os.path.realpath(item.get("file", "")) != real_target]

    for idx, item in enumerate(playlist):
        item["order"] = idx + 1

    save_json(playlist_path, playlist)

    subprocess.run([script_path("generate_playlist.sh"), cdir])
    restart_output(cdir, "hls-main")

    return redirect(f"/channel/{channel}")


@app.route("/channel/<channel>/playlist/save", methods=["POST"])
def save_playlist(channel):
    cdir = channel_dir(channel)
    cfg = load_json(os.path.join(cdir, "channel.json"), {})

    playlist_path = os.path.join(
        cdir,
        cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
    )

    files = request.form.getlist("file")
    titles = request.form.getlist("title")
    durations = request.form.getlist("duration_seconds")
    enabled_values = request.form.getlist("enabled_value")
    audio_source_ids = request.form.getlist("audio_source_id")
    video_source_ids = request.form.getlist("video_source_id")

    playlist = []

    for idx, file_path in enumerate(files):
        try:
            duration = float(durations[idx])
        except Exception:
            duration = 0

        enabled = False
        if idx < len(enabled_values):
            enabled = enabled_values[idx].lower() == "true"

        playlist.append({
            "order": idx + 1,
            "enabled": enabled,
            "title": titles[idx] if idx < len(titles) else os.path.basename(file_path),
            "file": file_path,
            "duration_seconds": duration,
            "audio_source_id": audio_source_ids[idx] if idx < len(audio_source_ids) else "embedded",
            "video_source_id": video_source_ids[idx] if idx < len(video_source_ids) else "file"
        })

    save_json(playlist_path, playlist)
    subprocess.run([script_path("generate_playlist.sh"), cdir])

    # Apply playlist changes immediately using the same stop/start/wait behavior
    # as the channel audio selector. This keeps the user experience consistent.
    try:
        subprocess.run(
            [script_path("stop_output.sh"), cdir, "hls-main"],
            timeout=10
        )

        subprocess.Popen(
            [script_path("start_output.sh"), cdir, "hls-main"]
        )

        status_path = os.path.join(cdir, "runtime", "status", "hls-main.json")
        stream_path = os.path.join(os.environ.get("HLS_ROOT", "/var/www/html/hls"), "Ch_" + channel, "stream.m3u8")

        # Give FFmpeg time to relaunch and write a usable HLS playlist.
        for _ in range(20):
            status = load_json(status_path, {})
            if (
                status.get("status") == "running"
                and os.path.exists(stream_path)
                and os.path.getsize(stream_path) > 100
            ):
                break
            time.sleep(0.5)

    except Exception as e:
        print(f"Playlist output restart failed: {e}")

    return redirect(f"/channel/{channel}")



@app.route("/channel/<channel>/encoder/select", methods=["POST"])
def select_channel_encoder(channel):
    cdir = channel_dir(channel)
    cfg_path = os.path.join(cdir, "channel.json")
    cfg = load_json(cfg_path, {})

    requested = request.form.get("video_encoder_requested", "auto").strip().lower()
    valid = ["auto", "intel", "nvidia", "cpu", "vaapi", "nvenc", "x264"]

    if requested not in valid:
        requested = "auto"

    # Normalize aliases for cleaner config.
    aliases = {
        "vaapi": "intel",
        "nvenc": "nvidia",
        "x264": "cpu"
    }
    requested = aliases.get(requested, requested)

    cfg["video_encoder_requested"] = requested
    save_json(cfg_path, cfg)

    # Apply immediately by restarting HLS output.
    try:
        stop_script = script_path("stop_output.sh") if "script_path" in globals() else "/opt/streaming-engine-beta/scripts/stop_output.sh"
        start_script = script_path("start_output.sh") if "script_path" in globals() else "/opt/streaming-engine-beta/scripts/start_output.sh"

        subprocess.run([stop_script, cdir, "hls-main"], timeout=10)
        subprocess.Popen([start_script, cdir, "hls-main"])
    except Exception as e:
        print(f"Encoder output restart failed: {e}")

    return redirect(f"/channel/{channel}")


@app.route("/channel/<channel>/output/<output_id>/<action>", methods=["POST"])
def output_action(channel, output_id, action):
    cdir = channel_dir(channel)
    script = "start_output.sh" if action == "start" else "stop_output.sh"

    subprocess.Popen([script_path(script), cdir, output_id])

    return redirect(f"/channel/{channel}")


@app.route("/channel/<channel>/flush", methods=["POST"])
def flush_channel(channel):
    cdir = channel_dir(channel)
    cfg = load_json(os.path.join(cdir, "channel.json"), {})

    outputs_dir = os.path.join(cdir, cfg.get("paths", {}).get("outputs", "outputs"))

    if os.path.isdir(outputs_dir):
        for output_file in os.listdir(outputs_dir):
            if not output_file.endswith(".json"):
                continue

            output = load_json(os.path.join(outputs_dir, output_file), {})
            output_id = output.get("output_id")

            if output_id:
                subprocess.run([script_path("stop_output.sh"), cdir, output_id])

    folders = [
        "incoming", "production", "processed", "failed",
        "runtime/logs", "runtime/pids", "runtime/status", "runtime/cache"
    ]

    for rel in folders:
        path = os.path.join(cdir, rel)
        if os.path.isdir(path):
            for name in os.listdir(path):
                target = os.path.join(path, name)
                if os.path.isfile(target):
                    os.remove(target)

    for rel in ["playlists/human_playlist.json", "playlists/ffmpeg_playlist.txt"]:
        path = os.path.join(cdir, rel)
        if os.path.exists(path):
            os.remove(path)

    return redirect(f"/channel/{channel}")



@app.route("/channel/add", methods=["POST"])
def add_channel():
    import re
    import json
    from pathlib import Path

    channel_id = request.form.get("channel_id", "").strip()
    friendly_name = request.form.get("friendly_name", "").strip()
    hls_name = ""
    output_file = request.form.get("output_file", "stream.m3u8").strip()

    channel_id = re.sub(r"[^A-Za-z0-9_-]", "", channel_id.replace(" ", "_"))
    if not channel_id:
        channel_id = "Channel1"

    if not friendly_name:
        friendly_name = channel_id

    hls_name = "Ch_" + channel_id

    if not output_file.endswith(".m3u8"):
        output_file = "stream.m3u8"

    cdir = Path(CHANNELS_BASE) / channel_id

    folders = [
        "incoming",
        "production",
        "processed",
        "failed",
        "playlists",
        "outputs",
        "runtime/logs",
        "runtime/pids",
        "runtime/status",
        "runtime/cache",
    ]

    for folder in folders:
        (cdir / folder).mkdir(parents=True, exist_ok=True)

    channel_json = cdir / "channel.json"
    if not channel_json.exists():
        channel_json.write_text(json.dumps({
            "channel_id": channel_id,
            "name": friendly_name,
            "files": {
                "human_playlist": "playlists/human_playlist.json",
                "ffmpeg_playlist": "playlists/ffmpeg_playlist.txt"
            },
            "active_audio_source_id": "embedded",
        }, indent=2) + "\n")

    human_playlist = cdir / "playlists/human_playlist.json"
    if not human_playlist.exists():
        human_playlist.write_text("[]\n")

    ffmpeg_playlist = cdir / "playlists/ffmpeg_playlist.txt"
    if not ffmpeg_playlist.exists():
        ffmpeg_playlist.write_text("")

    output_json = cdir / "outputs/hls-main.json"
    if not output_json.exists():
        output_json.write_text(json.dumps({
            "output_id": "hls-main",
            "name": "Main HLS Output",
            "type": "hls",
            "enabled": True,
            "autostart": False,
            "hls": {
                "output_dir": os.path.join(os.environ.get("HLS_ROOT", "/var/www/html/hls"), hls_name),
                "output_file": output_file,
                "hls_time": load_settings().get("default_hls_time", 4),
                "hls_list_size": load_settings().get("default_hls_list_size", 24)
            }
        }, indent=2) + "\n")

    return redirect(f"/channel/{channel_id}")



@app.route("/api/system/status")
def api_system_status():
    import json
    import subprocess
    import time
    from pathlib import Path

    status_path = Path("/tmp/custom-streaming-system-status.json")
    if status_path.exists():
        try:
            status = json.loads(status_path.read_text())
        except Exception:
            status = {}
    else:
        status = {}

    audio_devices = []

    try:
        result = subprocess.run(["arecord", "-l"], capture_output=True, text=True, timeout=3)
        if result.returncode == 0:
            audio_devices = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    except Exception:
        audio_devices = []

    status["audio_input_list"] = audio_devices
    status["audio_input_count"] = len(audio_devices)

    return jsonify(status)


@app.route("/channel/<channel>/delete", methods=["POST"])
def delete_channel(channel):
    import shutil
    import re
    from pathlib import Path

    confirm_one = request.form.get("confirm_one", "")
    confirm_two = request.form.get("confirm_two", "")

    if confirm_one != "yes" or confirm_two != "DELETE":
        return redirect("/")

    safe_channel = re.sub(r"[^A-Za-z0-9_-]", "", channel)

    if not safe_channel or safe_channel != channel:
        return redirect("/")

    cdir = Path(CHANNELS_BASE) / safe_channel

    # Stop any running output before deleting files.
    if cdir.exists() and cdir.is_dir():
        try:
            subprocess.run(
                [script_path("stop_output.sh"), str(cdir), "hls-main"],
                timeout=10
            )
        except Exception as e:
            print(f"Delete channel stop_output failed: {e}")

    if cdir.exists() and cdir.is_dir():
        shutil.rmtree(cdir)

    # Remove stale HLS output so recreated channels don't play old segments.
    hls_dir = Path("/var/www/html/hls") / ("Ch_" + safe_channel)
    if hls_dir.exists() and hls_dir.is_dir():
        shutil.rmtree(hls_dir)

    return redirect("/")


def build_network_policy_preview(settings):
    policy = settings.get("network_policy", {})
    audio_sources = settings.get("audio_sources", [])
    hls_port = settings.get("hls_port", 8088)
    web_port = settings.get("web_port", 5000)

    lines = []
    lines.append("MODE: " + str(policy.get("mode", "preview")).upper())
    lines.append("")
    lines.append("DEFAULT POLICY")
    lines.append("- Inbound: DROP unless explicitly allowed")
    lines.append("- Outbound: DROP unless explicitly allowed")
    lines.append("- Established/related traffic: ALLOW")
    lines.append("")

    lines.append("ALLOWED LAN SUBNETS")
    if policy.get("auto_allow_lan", True):
        lines.append("- Auto-detect local LAN subnets: ENABLED")
    for subnet in policy.get("manual_allowed_subnets", []):
        lines.append("- Manual allow: " + subnet)
    lines.append("")

    lines.append("INBOUND ALLOW RULES")
    if policy.get("allow_web_ui_from_lan", True):
        lines.append(f"- Allow LAN to Web UI TCP/{web_port}")
    if policy.get("allow_hls_from_lan", True):
        lines.append(f"- Allow LAN to HLS TCP/{hls_port}")
    if policy.get("allow_vnc_from_lan", False):
        lines.append("- Allow LAN to VNC/noVNC TCP/5901,6901")
    if policy.get("allow_public_access", False):
        lines.append("- Public inbound access: ENABLED")
    else:
        lines.append("- Public inbound access: DISABLED")
    lines.append("")

    lines.append("OUTBOUND ALLOW RULES")
    if policy.get("allow_dns", True):
        lines.append("- Allow DNS UDP/TCP 53 to configured resolvers")
    if policy.get("allow_ntp", True):
        lines.append("- Allow NTP UDP/123 to " + str(policy.get("ntp_server", "pool.ntp.org")))

    if policy.get("allow_configured_audio_sources", True):
        for src in audio_sources:
            url = src.get("url", "")
            typ = src.get("type", "")
            sid = src.get("id", "")
            if url and typ in ["web", "hls"]:
                lines.append(f"- Allow audio source {sid}: {url}")

    if policy.get("allow_configured_outputs", True):
        lines.append("- Allow configured output destinations only")

    if policy.get("allow_multicast_when_configured", True):
        lines.append("- Allow multicast only for configured multicast inputs/outputs")
    lines.append("")

    lines.append("TIME / LOGGING")
    lines.append("- Timezone: " + str(policy.get("timezone", "America/Chicago")))
    lines.append("- NTP server: " + str(policy.get("ntp_server", "pool.ntp.org")))
    lines.append("- Internal timestamps should remain UTC")
    lines.append("- Web UI should display friendly local time")
    lines.append("")

    lines.append("MAINTENANCE MODE")
    if policy.get("maintenance_mode", False):
        lines.append("- Maintenance mode: ENABLED")
    else:
        lines.append("- Maintenance mode: disabled")
    lines.append("- Maintenance timeout minutes: " + str(policy.get("maintenance_timeout_minutes", 30)))

    return "\\n".join(lines)


@app.route("/engineer")
def engineer():
    import os
    import json
    from pathlib import Path

    channels = []
    base = Path(CHANNELS_BASE)

    if base.exists():
        for item in sorted(base.iterdir()):
            if not item.is_dir():
                continue

            cfg_path = item / "channel.json"
            cfg = load_json(str(cfg_path), {})

            outputs = []
            outputs_dir = item / "outputs"
            if outputs_dir.exists():
                for f in sorted(outputs_dir.glob("*.json")):
                    outputs.append(load_json(str(f), {}))

            channels.append({
                "id": item.name,
                "name": cfg.get("name", item.name),
                "config": cfg,
                "outputs": outputs,
                "audio_sources": cfg.get("audio_sources", [])
            })

    status_path = Path("/tmp/custom-streaming-system-status.json")
    system_status = {}
    if status_path.exists():
        try:
            system_status = json.loads(status_path.read_text())
        except Exception:
            system_status = {}

    settings = load_settings()
    return render_template(
        "engineer.html",
        channels=channels,
        system_status=system_status,
        settings=settings,
        audio_sources=get_audio_sources(),
        network_policy_preview=build_network_policy_preview(settings)
    )


@app.route("/engineer/network/save", methods=["POST"])
def save_network_policy():
    settings = load_settings()
    policy = settings.get("network_policy", DEFAULT_SETTINGS.get("network_policy", {}).copy())

    policy["mode"] = request.form.get("mode", policy.get("mode", "preview"))
    policy["timezone"] = request.form.get("timezone", policy.get("timezone", "America/Chicago")).strip()
    policy["ntp_server"] = request.form.get("ntp_server", policy.get("ntp_server", "pool.ntp.org")).strip()

    subnets_raw = request.form.get("manual_allowed_subnets", "")
    policy["manual_allowed_subnets"] = [
        x.strip() for x in subnets_raw.replace(",", "\\n").splitlines() if x.strip()
    ]

    for key in [
        "auto_allow_lan",
        "allow_web_ui_from_lan",
        "allow_hls_from_lan",
        "allow_vnc_from_lan",
        "allow_public_access",
        "allow_dns",
        "allow_ntp",
        "allow_configured_audio_sources",
        "allow_configured_outputs",
        "allow_multicast_when_configured",
        "maintenance_mode"
    ]:
        policy[key] = request.form.get(key, "off") == "on"

    try:
        policy["maintenance_timeout_minutes"] = int(request.form.get("maintenance_timeout_minutes", policy.get("maintenance_timeout_minutes", 30)))
    except Exception:
        policy["maintenance_timeout_minutes"] = 30

    settings["network_policy"] = policy
    save_settings(settings)

    return redirect("/engineer?tab=network")


@app.route("/api/audio/test", methods=["POST"])
def api_audio_test():
    import subprocess
    import time
    import json

    source_type = request.form.get("source_type", "web").strip()
    url = request.form.get("url", "").strip()

    if source_type not in ["web", "hls"] or not url:
        return jsonify({
            "ok": False,
            "error": "Only web/HLS URL audio test is currently supported."
        })

    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-t", "5",
        "-i", url,
        "-af", "volumedetect",
        "-f", "null",
        "-"
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=12)
        output = (result.stderr or "") + (result.stdout or "")

        mean_volume = None
        max_volume = None

        for line in output.splitlines():
            if "mean_volume:" in line:
                mean_volume = line.split("mean_volume:", 1)[1].strip()
            if "max_volume:" in line:
                max_volume = line.split("max_volume:", 1)[1].strip()

        return jsonify({
            "ok": result.returncode == 0,
            "mean_volume": mean_volume,
            "max_volume": max_volume,
            "raw_tail": "\n".join(output.splitlines()[-20:])
        })
    except Exception as e:
        return jsonify({
            "ok": False,
            "error": str(e)
        })


@app.route("/engineer/settings/save", methods=["POST"])
def save_engineer_settings():
    settings = load_settings()

    for key in [
        "web_port",
        "hls_port",
        "default_video_bitrate",
        "default_audio_bitrate",
        "default_hls_time",
        "default_hls_list_size",
        "target_lufs",
        "true_peak",
        "loudness_range",
        "output_gain_db",
        "limiter_limit"
    ]:
        try:
            settings[key] = int(request.form.get(key, settings.get(key)))
        except Exception:
            pass

    settings["default_encoder"] = request.form.get("default_encoder", settings.get("default_encoder", "auto"))
    settings["normalize_embedded_audio"] = request.form.get("normalize_embedded_audio", "off") == "on"

    save_settings(settings)
    return redirect("/engineer?tab=settings")


@app.route("/api/channel/<channel>/stats")
def api_channel_stats(channel):
    import subprocess
    import time
    import json
    import os
    import glob
    from pathlib import Path

    cdir, cfg, playlist = load_channel_data(channel)
    outputs, primary_stream_url = load_outputs(channel, cdir, cfg)

    stats = {
        "channel": channel,
        "primary_stream_url": primary_stream_url,
        "playlist": [],
        "outputs": [],
        "hls": {}
    }

    def probe_media(path):
        if not path or not os.path.exists(path):
            return {}

        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v", "quiet",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    path
                ],
                capture_output=True,
                text=True,
                timeout=15
            )
            if result.returncode != 0:
                return {"error": result.stderr[-1000:]}
            return json.loads(result.stdout or "{}")
        except Exception as e:
            return {"error": str(e)}

    for item in playlist:
        media_stats = probe_media(item.get("file"))
        video = {}
        audio = {}

        for stream in media_stats.get("streams", []):
            if stream.get("codec_type") == "video" and not video:
                video = {
                    "codec": stream.get("codec_name"),
                    "width": stream.get("width"),
                    "height": stream.get("height"),
                    "pix_fmt": stream.get("pix_fmt"),
                    "avg_frame_rate": stream.get("avg_frame_rate"),
                    "r_frame_rate": stream.get("r_frame_rate"),
                    "bit_rate": stream.get("bit_rate")
                }
            if stream.get("codec_type") == "audio" and not audio:
                audio = {
                    "codec": stream.get("codec_name"),
                    "sample_rate": stream.get("sample_rate"),
                    "channels": stream.get("channels"),
                    "channel_layout": stream.get("channel_layout"),
                    "bit_rate": stream.get("bit_rate")
                }

        stats["playlist"].append({
            "title": item.get("title"),
            "file": item.get("file"),
            "enabled": item.get("enabled"),
            "duration_seconds": item.get("duration_seconds"),
            "video": video,
            "audio": audio
        })

    for output in outputs:
        hls = output.get("hls", {})
        output_dir = hls.get("output_dir")
        segment_files = []
        folder_size = 0

        if output_dir and os.path.isdir(output_dir):
            segment_files = sorted(glob.glob(os.path.join(output_dir, "*.ts")))
            for f in segment_files:
                try:
                    folder_size += os.path.getsize(f)
                except Exception:
                    pass

        stats["outputs"].append({
            "output_id": output.get("output_id"),
            "name": output.get("name"),
            "type": output.get("type"),
            "status": output.get("status", {}),
            "hls": {
                "output_dir": output_dir,
                "actual_public_url": hls.get("actual_public_url"),
                "segment_count": len(segment_files),
                "folder_size_bytes": folder_size,
                "latest_segment": os.path.basename(segment_files[-1]) if segment_files else None,
                "latest_segment_age_seconds": (
                    round(__import__("time").time() - os.path.getmtime(segment_files[-1]), 2)
                    if segment_files else None
                )
            }
        })

    return jsonify(stats)


@app.route("/system")
def system_page():
    return render_template("system.html")

@app.route("/api/system/inventory")
def api_system_inventory():
    import subprocess, json
    script = "/opt/streaming-engine-beta/scripts/system_snapshot.sh"
    if not os.path.exists(script):
        script = os.path.join(os.path.dirname(os.path.dirname(__file__)), "scripts", "system_snapshot.sh")
    try:
        r = subprocess.run([script], capture_output=True, text=True, timeout=10)
        return jsonify(json.loads(r.stdout))
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route("/api/system/events")
def api_system_events():
    root = os.environ.get("CHANNEL_ROOT", "/var/lib/streaming-engine-beta/channels")
    events = []
    try:
        for name in sorted(os.listdir(root)):
            if name == "system":
                continue
            p = os.path.join(root, name, "runtime", "logs", "events.log")
            if os.path.exists(p):
                with open(p, "r", errors="ignore") as f:
                    for line in f.readlines()[-50:]:
                        events.append({"channel": name, "line": line.rstrip()})
    except Exception as e:
        return jsonify({"error": str(e), "events": events})
    return jsonify({"events": events[-100:]})

@app.route("/api/system/channel-health")
def api_system_channel_health():
    import time, re
    root = os.environ.get("CHANNEL_ROOT", "/var/lib/streaming-engine-beta/channels")
    hls_root = os.environ.get("HLS_ROOT", "/var/www/html/hls")
    out = []
    now = time.time()
    try:
        for name in sorted(os.listdir(root)):
            if name == "system":
                continue
            cdir = os.path.join(root, name)
            if not os.path.isdir(cdir):
                continue
            status_path = os.path.join(cdir, "runtime", "status", "hls-main.json")
            log_path = os.path.join(cdir, "runtime", "logs", "hls-main.log")
            stream_path = os.path.join(hls_root, "Ch_" + name, "stream.m3u8")
            status = load_json(status_path, {})
            age = None
            if os.path.exists(stream_path):
                age = int(now - os.path.getmtime(stream_path))
            speed = None
            if os.path.exists(log_path):
                try:
                    data = open(log_path, "r", errors="ignore").read()[-20000:]
                    m = re.findall(r"speed=\s*([0-9.]+)x", data)
                    if m:
                        speed = m[-1]
                except Exception:
                    pass
            out.append({
                "channel": name,
                "status": status.get("status", "unknown"),
                "encoder": status.get("video_encoder", ""),
                "audio_source_id": status.get("audio_source_id", ""),
                "audio_source_type": status.get("audio_source_type", ""),
                "last_segment_age_seconds": age,
                "ffmpeg_speed": speed,
                "healthy": bool(age is not None and age < 90)
            })
    except Exception as e:
        return jsonify({"error": str(e), "channels": out})
    return jsonify({"channels": out})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)






