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
from datetime import datetime, timezone

app = Flask(__name__)
CHANNELS_BASE = "/channels"


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
    subprocess.run(["/opt/custom-streaming/scripts/stop_output.sh", cdir, output_id])
    subprocess.run(["bash", "-c", "rm -f /var/www/html/hls/channel1/*"])
    subprocess.run(["bash", "-c", f"rm -f {cdir}/runtime/pids/*"])
    subprocess.run(["bash", "-c", f"rm -f {cdir}/runtime/status/*"])
    subprocess.run(["/opt/custom-streaming/scripts/start_output.sh", cdir, output_id])


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

    hls_public_port = os.environ.get("HLS_PUBLIC_PORT", "8088")
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


@app.route("/")
def index():
    channels = []

    for name in sorted(os.listdir(CHANNELS_BASE)):
        cdir = os.path.join(CHANNELS_BASE, name)
        if not os.path.isdir(cdir):
            continue

        cfg = load_json(os.path.join(cdir, "channel.json"))

        if cfg:
            channels.append({"dir": cdir, "name": name, "config": cfg})

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
        audio_sources=cfg.get("audio_sources", []),
        video_sources=cfg.get("video_sources", [])
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


@app.route("/channel/<channel>/audio-source/add", methods=["POST"])
def add_audio_source(channel):
    cdir = channel_dir(channel)
    cfg_path = os.path.join(cdir, "channel.json")
    cfg = load_json(cfg_path, {})

    source_id = request.form.get("source_id", "").strip()
    friendly_name = request.form.get("friendly_name", "").strip()
    source_type = request.form.get("source_type", "web").strip()
    url = request.form.get("url", "").strip()

    import re
    source_id = re.sub(r"[^A-Za-z0-9_-]", "", source_id.replace(" ", "_"))

    if not source_id:
        return redirect(f"/channel/{channel}")

    if not friendly_name:
        friendly_name = source_id

    cfg.setdefault("audio_sources", [])
    cfg["audio_sources"] = [s for s in cfg["audio_sources"] if s.get("id") != source_id]

    cfg["audio_sources"].append({
        "id": source_id,
        "friendly_name": friendly_name,
        "type": source_type,
        "url": url
    })

    save_json(cfg_path, cfg)

    return redirect(f"/channel/{channel}")

@app.route("/channel/<channel>/audio-source/delete", methods=["POST"])
def delete_audio_source(channel):
    cdir = channel_dir(channel)
    cfg_path = os.path.join(cdir, "channel.json")
    cfg = load_json(cfg_path, {})

    source_id = request.form.get("source_id", "").strip()

    if source_id in ["embedded", "silent"]:
        return redirect(f"/channel/{channel}")

    cfg.setdefault("audio_sources", [])
    cfg["audio_sources"] = [s for s in cfg["audio_sources"] if s.get("id") != source_id]

    playlist_path = os.path.join(
        cdir,
        cfg.get("files", {}).get("human_playlist", "playlists/human_playlist.json")
    )

    playlist = load_json(playlist_path, [])
    for item in playlist:
        if item.get("audio_source_id") == source_id:
            item["audio_source_id"] = "embedded"

    save_json(cfg_path, cfg)
    save_json(playlist_path, playlist)

    return redirect(f"/channel/{channel}")


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
            "/opt/custom-streaming/scripts/prestage.sh",
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

    subprocess.run(["/opt/custom-streaming/scripts/generate_playlist.sh", cdir])
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
    subprocess.run(["/opt/custom-streaming/scripts/generate_playlist.sh", cdir])
    restart_output(cdir, "hls-main")

    return redirect(f"/channel/{channel}")


@app.route("/channel/<channel>/output/<output_id>/<action>", methods=["POST"])
def output_action(channel, output_id, action):
    cdir = channel_dir(channel)
    script = "start_output.sh" if action == "start" else "stop_output.sh"

    subprocess.Popen(["/opt/custom-streaming/scripts/" + script, cdir, output_id])

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
                subprocess.run(["/opt/custom-streaming/scripts/stop_output.sh", cdir, output_id])

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

    cdir = Path("/channels") / channel_id

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
            "audio_sources": [
                {
                    "id": "embedded",
                    "friendly_name": "Embedded File Audio",
                    "type": "embedded",
                    "url": ""
                },
                {
                    "id": "silent",
                    "friendly_name": "Silent / No Audio",
                    "type": "silent",
                    "url": ""
                }
            ]
        }, indent=2) + "\n")

    human_playlist = cdir / "playlists/human_playlist.json"
    if not human_playlist.exists():
        human_playlist.write_text("[]`n")

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
                "output_dir": f"/var/www/html/hls/{hls_name}",
                "output_file": output_file,
                "hls_time": 4,
                "hls_list_size": 12
            }
        }, indent=2) + "\n")

    return redirect(f"/channel/{channel_id}")



@app.route("/api/system/status")
def api_system_status():
    import json
    import subprocess
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

    if cdir.exists() and cdir.is_dir():
        shutil.rmtree(cdir)

    return redirect("/")


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

    return render_template("engineer.html", channels=channels, system_status=system_status)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)






