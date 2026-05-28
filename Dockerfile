FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update && apt install -y \
    ffmpeg \
    nginx \
    jq \
    python3 \
    python3-pip \
    python3-flask \
    curl \
    wget \
    nano \
    procps \
    psmisc \
    ca-certificates \
    vainfo \
    intel-media-va-driver-non-free \
    intel-gpu-tools \
    mesa-va-drivers \
    libva2 \
    libva-drm2 \
    libva-x11-2 \
    libmfx1 \
    libvpl2 \
    && apt clean \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p \
    /opt/custom-streaming/scripts \
    /opt/custom-streaming/web \
    /var/www/html/hls

COPY scripts/ /opt/custom-streaming/scripts/
COPY web/ /opt/custom-streaming/web/
COPY nginx/default /etc/nginx/sites-available/default

RUN chmod +x /opt/custom-streaming/scripts/*.sh

EXPOSE 80 5000

CMD ["/opt/custom-streaming/scripts/container_start.sh"]
