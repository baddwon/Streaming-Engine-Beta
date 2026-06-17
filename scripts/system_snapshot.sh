#!/bin/bash
set -euo pipefail

echo "{"
echo '"timestamp": "'"$(date -Is)"'",'

echo '"cpu": {'
echo '"model": "'"$(lscpu | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' | sed 's/"/\\"/g')"'",'
echo '"load": "'"$(uptime | sed 's/.*load average: //')"'",'
echo '"percent": '"$(awk '{u=$2+$4; t=$2+$4+$5; if (t>0) printf "%.1f", (u/t)*100; else print 0}' /proc/stat)"
echo "},"

echo '"memory": {'
free -m | awk '/Mem:/ {printf "\"total_mb\": %s, \"used_mb\": %s, \"free_mb\": %s, \"percent\": %.1f\n",$2,$3,$4,($3/$2)*100}'
echo "},"

echo '"disk": {'
df -h / | awk 'NR==2 {gsub("%","",$5); printf "\"root_size\": \"%s\", \"root_used\": \"%s\", \"root_avail\": \"%s\", \"root_percent\": %s\n",$2,$3,$4,$5}'
echo "},"

echo '"gpus": ['
first=1
if command -v nvidia-smi >/dev/null 2>&1; then
  while IFS=',' read -r name driver util enc dec mem_used mem_total temp; do
    [ "$first" = 1 ] || echo ","
    first=0
    name="$(echo "$name" | sed 's/^ *//;s/ *$//;s/"/\\"/g')"
    driver="$(echo "$driver" | sed 's/^ *//;s/ *$//')"
    echo -n "{\"vendor\":\"nvidia\",\"name\":\"$name\",\"driver\":\"$driver\",\"gpu_percent\":$util,\"encoder_percent\":$enc,\"decoder_percent\":$dec,\"memory_used_mb\":$mem_used,\"memory_total_mb\":$mem_total,\"temperature_c\":$temp,\"nvenc\":true}"
  done < <(nvidia-smi --query-gpu=name,driver_version,utilization.gpu,utilization.encoder,utilization.decoder,memory.used,memory.total,temperature.gpu --format=csv,noheader,nounits 2>/dev/null || true)
fi
for dev in /dev/dri/renderD*; do
  [ -e "$dev" ] || continue
  [ "$first" = 1 ] || echo ","
  first=0
  echo -n "{\"vendor\":\"intel_or_vaapi\",\"name\":\"$dev\",\"vaapi\":true}"
done
echo "],"

echo '"services": {'
echo '"streaming_engine": "'"$(systemctl is-active streaming-engine-beta 2>/dev/null || echo unknown)"'",'
echo '"watchdog_timer": "'"$(systemctl is-active streaming-engine-watchdog.timer 2>/dev/null || echo unknown)"'",'
echo '"nginx": "'"$(systemctl is-active nginx 2>/dev/null || echo unknown)"'"'
echo "}"

echo "}"
