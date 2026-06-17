#!/bin/bash
set -euo pipefail

APP_NAME="streaming-engine-beta"
CONFIG_DIR="/etc/${APP_NAME}"
ENV_FILE="${CONFIG_DIR}/env"

[ -f "$ENV_FILE" ] && . "$ENV_FILE"

STREAMING_ENGINE_CONFIG="${STREAMING_ENGINE_CONFIG:-/var/lib/streaming-engine-beta/channels/system/settings.json}"
HLS_ROOT="${HLS_ROOT:-/var/www/html/hls}"
HLS_PUBLIC_PORT="${HLS_PUBLIC_PORT:-8088}"

PUBLIC_ENABLED="$(jq -r '.public_hls_enabled // false' "$STREAMING_ENGINE_CONFIG" 2>/dev/null || echo false)"

mapfile -t CIDRS < <(jq -r '.public_hls_allowed_cidrs[]? // empty' "$STREAMING_ENGINE_CONFIG" 2>/dev/null | sed '/^[[:space:]]*$/d')

SITE="/etc/nginx/sites-available/${APP_NAME}-hls"

{
cat <<NGINX
server {
    listen ${HLS_PUBLIC_PORT};
    server_name _;

    location /hls/ {
        root /var/www/html;
        add_header Access-Control-Allow-Origin * always;
        add_header Access-Control-Allow-Methods "GET, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Origin, Range, Accept, Content-Type" always;

NGINX

if [ "$PUBLIC_ENABLED" = "true" ] && [ "${#CIDRS[@]}" -gt 0 ]; then
  for cidr in "${CIDRS[@]}"; do
    echo "        allow ${cidr};"
  done
  echo "        deny all;"
else
  echo "        allow all;"
fi

cat <<'NGINX'

        types {
            application/vnd.apple.mpegurl m3u8;
            video/mp2t ts;
        }

        if ($request_method = OPTIONS) {
            return 204;
        }
    }
}
NGINX
} > "$SITE"

ln -sf "$SITE" "/etc/nginx/sites-enabled/${APP_NAME}-hls"

nginx -t
systemctl reload nginx

echo "Applied public HLS ACL rules to ${SITE}"
