# restic + rclone (Google Drive backend) for ~/HomeLab/backup/backup.sh
# rclone: official release binary, checksum-verified (Alpine's packaged rclone 1.66-DEV silently lost
# uploads to Google Drive on 2026-11-03).
FROM restic/restic:0.19.1
ARG RCLONE_VERSION=v1.75.2
RUN apk add --no-cache curl unzip \
 && cd /tmp \
 && curl -fsSLO "https://downloads.rclone.org/${RCLONE_VERSION}/rclone-${RCLONE_VERSION}-linux-amd64.zip" \
 && curl -fsSL "https://downloads.rclone.org/${RCLONE_VERSION}/SHA256SUMS" | grep "rclone-${RCLONE_VERSION}-linux-amd64.zip" | sha256sum -c - \
 && unzip -q "rclone-${RCLONE_VERSION}-linux-amd64.zip" \
 && install -m 755 "rclone-${RCLONE_VERSION}-linux-amd64/rclone" /usr/local/bin/rclone \
 && rm -rf /tmp/rclone-* \
 && apk del curl unzip
