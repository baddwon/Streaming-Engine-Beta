#!/usr/bin/env bash
set -euo pipefail

APP_NAME="streaming-engine-beta"
APP_USER="streaming"
APP_GROUP="streaming"

APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="/opt/${APP_NAME}"
CONFIG_DIR="/etc/${APP_NAME}"
DATA_DIR="/var/lib/${APP_NAME}"
CHANNEL_DIR="${DATA_DIR}/channels"
LOG_DIR="/var/log/${APP_NAME}"
RUN_DIR="/run/${APP_NAME}"
HLS_DIR="/var/www/html/hls"

WEB_PORT="${WEB_PORT:-5000}"
HLS_PUBLIC_PORT="${HLS_PUBLIC_PORT:-8088}"

echo "[INSTALL] Installing OS dependencies..."
sudo apt update
sudo apt install -y \
  ffmpeg \
  nginx \
  python3 \
  python3-pip \
  python3-venv \
  jq \
  inotify-tools \
  curl \
  ca-certificates

echo "[INSTALL] Creating service user..."
if ! id "${APP_USER}" >/dev/null 2>&1; then
  sudo useradd --system --home "${DATA_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

echo "[INSTALL] Creating directories..."
sudo mkdir -p "${APP_DIR}" "${CONFIG_DIR}" "${CHANNEL_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${HLS_DIR}"
sudo mkdir -p "${CHANNEL_DIR}/system/assets/maintenance"

echo "[INSTALL] Copying application files..."
sudo rsync -a --delete \
  --exclude ".git" \
  --exclude "dist" \
  --exclude "venv" \
  --exclude ".venv" \
  --exclude "__pycache__" \
  --exclude "*.pyc" \
  "${APP_SRC}/" "${APP_DIR}/"

echo "[INSTALL] Creating Python virtual environment..."
sudo python3 -m venv "${APP_DIR}/venv"
sudo "${APP_DIR}/venv/bin/pip" install --upgrade pip
if [ -f "${APP_DIR}/requirements.txt" ]; then
  sudo "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
else
  sudo "${APP_DIR}/venv/bin/pip" install flask requests
fi

echo "[INSTALL] Setting permissions..."
sudo chown -R root:root "${APP_DIR}"
sudo chown -R "${APP_USER}:${APP_GROUP}" "${DATA_DIR}" "${LOG_DIR}" "${RUN_DIR}" "${HLS_DIR}"
sudo chmod +x "${APP_DIR}/scripts/"*.sh 2>/dev/null || true

echo "[INSTALL] Writing environment file..."
sudo tee "${CONFIG_DIR}/env" >/dev/null <<ENV
APP_NAME=${APP_NAME}
CHANNEL_ROOT=${CHANNEL_DIR}
STREAMING_ENGINE_CONFIG=${CHANNEL_DIR}/system/settings.json
HLS_ROOT=${HLS_DIR}
WEB_PORT=${WEB_PORT}
HLS_PUBLIC_PORT=${HLS_PUBLIC_PORT}
PYTHONUNBUFFERED=1
ENV

echo "[INSTALL] Writing systemd service..."
sudo tee /etc/systemd/system/${APP_NAME}.service >/dev/null <<SERVICE
[Unit]
Description=Custom Streaming Engine Beta
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
EnvironmentFile=${CONFIG_DIR}/env
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/web/app.py
Restart=always
RestartSec=5

RuntimeDirectory=${APP_NAME}
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
SERVICE


echo "[INSTALL] Installing public HLS ACL helper..."
sudo chmod +x "${APP_DIR}/scripts/apply_public_hls_acl.sh" 2>/dev/null || true
sudo tee /etc/sudoers.d/${APP_NAME}-hls-acl >/dev/null <<SUDOERS
${APP_USER} ALL=(root) NOPASSWD: ${APP_DIR}/scripts/apply_public_hls_acl.sh
SUDOERS
sudo chmod 440 /etc/sudoers.d/${APP_NAME}-hls-acl

echo "[INSTALL] Configuring nginx HLS site..."
sudo tee /etc/nginx/sites-available/${APP_NAME}-hls >/dev/null <<NGINX
server {
    listen ${HLS_PUBLIC_PORT};
    server_name _;

    location /hls/ {
        root /var/www/html;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, Range, Accept, Content-Type" always;

        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }

        if (\$request_method = OPTIONS) {
            return 204;
        }
    }
}
NGINX

sudo ln -sf /etc/nginx/sites-available/${APP_NAME}-hls /etc/nginx/sites-enabled/${APP_NAME}-hls
sudo nginx -t
sudo systemctl reload nginx || sudo systemctl restart nginx


echo "[INSTALL] Installing output watchdog..."
sudo tee /etc/systemd/system/streaming-engine-watchdog.service >/dev/null <<WATCHDOGSERVICE
[Unit]
Description=Custom Streaming Engine Output Watchdog
After=${APP_NAME}.service
Wants=${APP_NAME}.service

[Service]
Type=oneshot
User=${APP_USER}
Group=${APP_GROUP}
EnvironmentFile=${CONFIG_DIR}/env
ExecStart=${APP_DIR}/scripts/watchdog_outputs.sh
WATCHDOGSERVICE

sudo tee /etc/systemd/system/streaming-engine-watchdog.timer >/dev/null <<WATCHDOGTIMER
[Unit]
Description=Run Custom Streaming Engine Output Watchdog every minute

[Timer]
OnBootSec=90
OnUnitActiveSec=60
AccuracySec=10
Persistent=true

[Install]
WantedBy=timers.target
WATCHDOGTIMER

echo "[INSTALL] Disabling sleep/hibernate targets for appliance mode..."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target || true

echo "[INSTALL] Enabling service..."
sudo systemctl daemon-reload
sudo systemctl enable ${APP_NAME}
sudo systemctl enable --now streaming-engine-watchdog.timer
sudo systemctl restart ${APP_NAME}

IP_ADDR="$(hostname -I | awk '{print $1}')"

echo
echo "[DONE] ${APP_NAME} installed."
echo "Web UI: http://${IP_ADDR}:${WEB_PORT}"
echo "HLS:    http://${IP_ADDR}:${HLS_PUBLIC_PORT}/hls/"
echo
echo "Check status:"
echo "  systemctl status ${APP_NAME}"
echo "  journalctl -u ${APP_NAME} -f"
