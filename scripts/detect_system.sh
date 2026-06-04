#!/bin/bash

ENV_FILE="/tmp/custom-streaming-encoder.env"
STATUS_FILE="/tmp/custom-streaming-system-status.json"

REQUESTED="${VIDEO_ENCODER:-auto}"
SELECTED="$REQUESTED"
REASON="Manual encoder override"

NVIDIA_STATE="not_available"
VAAPI_STATE="not_available"
AUDIO_STATE="not_available"

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
  NVIDIA_STATE="available"
fi

if [ -e /dev/dri/renderD128 ] && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_vaapi; then
  if command -v vainfo >/dev/null 2>&1; then
    if vainfo --display drm --device /dev/dri/renderD128 >/dev/null 2>&1; then
      VAAPI_STATE="available"
    else
      VAAPI_STATE="device_present_probe_failed"
    fi
  else
    VAAPI_STATE="device_present_no_vainfo"
  fi
fi

if [ -d /dev/snd ]; then
  AUDIO_STATE="mapped"
fi

if [ "$REQUESTED" = "auto" ]; then
  if [ "$NVIDIA_STATE" = "available" ]; then
    SELECTED="nvenc"
    REASON="NVIDIA NVENC detected"
  elif [ "$VAAPI_STATE" = "available" ]; then
    SELECTED="vaapi"
    REASON="VAAPI hardware encoder detected"
  else
    SELECTED="x264"
    REASON="No supported hardware encoder detected; using CPU x264"
  fi
fi

cat > "$ENV_FILE" <<EOF
export VIDEO_ENCODER="$SELECTED"
export VIDEO_ENCODER_REQUESTED="$REQUESTED"
export VIDEO_ENCODER_REASON="$REASON"
export NVIDIA_STATE="$NVIDIA_STATE"
export VAAPI_STATE="$VAAPI_STATE"
export AUDIO_STATE="$AUDIO_STATE"
EOF

cat > "$STATUS_FILE" <<EOF
{
  "video_encoder": "$SELECTED",
  "requested_encoder": "$REQUESTED",
  "reason": "$REASON",
  "nvidia": "$NVIDIA_STATE",
  "vaapi": "$VAAPI_STATE",
  "audio_devices": "$AUDIO_STATE"
}
EOF

echo "[INIT] Encoder selected: $SELECTED - $REASON"
