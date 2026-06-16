#!/bin/bash

ENV_FILE="/tmp/custom-streaming-encoder.env"
STATUS_FILE="/tmp/custom-streaming-system-status.json"

REQUESTED="${VIDEO_ENCODER_REQUESTED:-${VIDEO_ENCODER:-auto}}"
SELECTED="x264"
REASON="CPU fallback"

NVIDIA_STATE="not_available"
VAAPI_STATE="not_available"
AUDIO_STATE="not_available"
VAAPI_DEVICE=""

if command -v nvidia-smi >/dev/null 2>&1 \
  && nvidia-smi >/dev/null 2>&1 \
  && ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc; then
  NVIDIA_STATE="available"
fi

for dev in /dev/dri/renderD*; do
  [ -e "$dev" ] || continue
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_vaapi; then
    if command -v vainfo >/dev/null 2>&1; then
      if vainfo --display drm --device "$dev" >/dev/null 2>&1; then
        VAAPI_STATE="available"
        VAAPI_DEVICE="$dev"
        break
      else
        VAAPI_STATE="device_present_probe_failed"
      fi
    else
      VAAPI_STATE="device_present_no_vainfo"
      VAAPI_DEVICE="$dev"
      break
    fi
  fi
done

if [ -d /dev/snd ]; then
  AUDIO_STATE="mapped"
fi

case "$REQUESTED" in
  auto|"")
    if [ "$VAAPI_STATE" = "available" ] || [ "$VAAPI_STATE" = "device_present_no_vainfo" ]; then
      SELECTED="vaapi"
      REASON="Intel/onboard VAAPI selected by auto preference"
    elif [ "$NVIDIA_STATE" = "available" ]; then
      SELECTED="nvenc"
      REASON="NVIDIA NVENC selected because onboard VAAPI unavailable"
    else
      SELECTED="x264"
      REASON="No supported hardware encoder detected; using CPU x264"
    fi
    ;;
  intel|vaapi|qsv)
    if [ "$VAAPI_STATE" = "available" ] || [ "$VAAPI_STATE" = "device_present_no_vainfo" ]; then
      SELECTED="vaapi"
      REASON="Intel/onboard VAAPI manually selected"
    else
      SELECTED="x264"
      REASON="Intel/onboard requested but unavailable; using CPU x264"
    fi
    ;;
  nvidia|nvenc)
    if [ "$NVIDIA_STATE" = "available" ]; then
      SELECTED="nvenc"
      REASON="NVIDIA NVENC manually selected"
    else
      SELECTED="x264"
      REASON="NVIDIA requested but unavailable; using CPU x264"
    fi
    ;;
  cpu|x264)
    SELECTED="x264"
    REASON="CPU x264 manually selected"
    ;;
  *)
    SELECTED="x264"
    REASON="Unknown encoder request '$REQUESTED'; using CPU x264"
    ;;
esac

cat > "$ENV_FILE" <<EOV
export VIDEO_ENCODER="$SELECTED"
export VIDEO_ENCODER_REQUESTED="$REQUESTED"
export VIDEO_ENCODER_REASON="$REASON"
export NVIDIA_STATE="$NVIDIA_STATE"
export VAAPI_STATE="$VAAPI_STATE"
export VAAPI_DEVICE="$VAAPI_DEVICE"
export AUDIO_STATE="$AUDIO_STATE"
EOV

cat > "$STATUS_FILE" <<EOV
{
  "video_encoder": "$SELECTED",
  "requested_encoder": "$REQUESTED",
  "reason": "$REASON",
  "nvidia": "$NVIDIA_STATE",
  "vaapi": "$VAAPI_STATE",
  "vaapi_device": "$VAAPI_DEVICE",
  "audio_devices": "$AUDIO_STATE"
}
EOV

echo "[INIT] Encoder selected: $SELECTED - $REASON"
