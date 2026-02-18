#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 - Full Riven Stack Reset Script
# WARNING: This is destructive.
# It removes Docker, containers, images, volumes, Plex, Zurg, Zilean, Riven,
# rclone configs, systemd units, and related directories.

log(){ printf "\n==> %s\n" "$*"; }
warn(){ printf "\nWARN: %s\n" "$*" >&2; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo -i or su -)."
  exit 1
fi

log "Stopping systemd services created by installer"
systemctl disable --now rclone-zurg.service 2>/dev/null || true
systemctl disable --now riven-vfs-prepare.service 2>/dev/null || true
rm -f /etc/systemd/system/rclone-zurg.service
rm -f /etc/systemd/system/riven-vfs-prepare.service
systemctl daemon-reload

log "Unmounting mount points (if mounted)"
umount -lR /mnt/rd 2>/dev/null || true
umount -lR /opt/riven/vfs 2>/dev/null || true

if command -v docker >/dev/null 2>&1; then
  log "Stopping and removing Docker containers"
  docker ps -aq | xargs -r docker rm -f 2>/dev/null || true

  log "Removing Docker volumes"
  docker volume ls -q | xargs -r docker volume rm -f 2>/dev/null || true

  log "Removing Docker images"
  docker images -aq | xargs -r docker rmi -f 2>/dev/null || true

  log "Stopping Docker service"
  systemctl stop docker 2>/dev/null || true
fi

log "Removing stack directories"
rm -rf /opt/riven /opt/zilean /opt/zurg 2>/dev/null || true
rm -rf /mnt/rd 2>/dev/null || true
rm -rf /var/cache/rclone 2>/dev/null || true
rm -rf /root/.config/rclone 2>/dev/null || true

log "Removing Docker runtime data"
rm -rf /var/lib/docker 2>/dev/null || true
rm -rf /var/lib/containerd 2>/dev/null || true

log "Removing Plex"
systemctl disable --now plexmediaserver 2>/dev/null || true
apt-get purge -y plexmediaserver 2>/dev/null || true
rm -f /etc/apt/sources.list.d/plex*.list 2>/dev/null || true
rm -f /etc/apt/keyrings/plex.gpg 2>/dev/null || true

log "Removing Docker CE packages"
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
apt-get purge -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true
rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true

log "Reset complete"
echo "System is now in near pre-install state."
