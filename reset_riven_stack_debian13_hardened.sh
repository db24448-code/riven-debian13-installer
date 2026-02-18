#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 - Full Riven Stack Reset Script (hardened)
# WARNING: This is destructive.
#
# Goal: undo everything the installer changes:
# - systemd units (rclone-zurg, riven-vfs-prepare)
# - mounts (/mnt/rd, /opt/riven/vfs)
# - docker compose stacks + standalone containers
# - docker networks created by compose (and any custom networks used)
# - docker volumes/images
# - stack directories (/opt/riven /opt/zilean /opt/zurg), media/mount/cache dirs
# - rclone config + cache
# - installer tweaks (fuse.conf user_allow_other)
# - Plex install + repo/key
# - Docker CE install + repo/key
# - rclone package (installed by installer)

log(){ printf "\n==> %s\n" "$*"; }
warn(){ printf "\nWARN: %s\n" "$*" >&2; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: Run as root (sudo -i or su -)."
  exit 1
fi

# --- Stop/disable systemd services created by installer ---
log "Stopping systemd services created by installer"
systemctl disable --now rclone-zurg.service 2>/dev/null || true
systemctl disable --now riven-vfs-prepare.service 2>/dev/null || true
rm -f /etc/systemd/system/rclone-zurg.service
rm -f /etc/systemd/system/riven-vfs-prepare.service
systemctl daemon-reload

# --- Unmount anything the installer mounted/bound ---
log "Unmounting mount points (if mounted)"
umount -lR /mnt/rd 2>/dev/null || true
umount -lR /opt/riven/vfs 2>/dev/null || true

# --- Tear down compose projects cleanly (in case not all containers were removed) ---
if command -v docker >/dev/null 2>&1; then
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if [[ -f /opt/riven/docker-compose.yml ]]; then
      log "Bringing down Riven compose project (/opt/riven)"
      (cd /opt/riven && docker compose --env-file .env down --remove-orphans --volumes) 2>/dev/null || true
    fi
    if [[ -f /opt/zilean/docker-compose.yml ]]; then
      log "Bringing down Zilean compose project (/opt/zilean)"
      (cd /opt/zilean && docker compose down --remove-orphans --volumes) 2>/dev/null || true
    fi
  fi

  # --- Remove containers (including zurg run as standalone) ---
  log "Stopping and removing all Docker containers"
  docker ps -aq | xargs -r docker rm -f 2>/dev/null || true

  # --- Remove custom networks commonly created by this stack ---
  # Compose networks are usually removed by 'down', but if files are gone or partially failed, clean them here.
  log "Removing Docker networks created by stack (best-effort)"
  for net in zilean-net riven_default zilean_default zurg_default media-net; do
    docker network rm "$net" 2>/dev/null || true
  done

  # --- Remove all Docker volumes/images (nuclear option; matches your current reset intent) ---
  log "Removing Docker volumes"
  docker volume ls -q | xargs -r docker volume rm -f 2>/dev/null || true

  log "Removing Docker images"
  docker images -aq | xargs -r docker rmi -f 2>/dev/null || true

  log "Stopping Docker service"
  systemctl stop docker 2>/dev/null || true
  systemctl disable docker 2>/dev/null || true
fi

# --- Remove stack directories and data paths created by installer ---
log "Removing stack directories"
rm -rf /opt/riven /opt/zilean /opt/zurg 2>/dev/null || true

log "Removing mount/media/cache dirs created by installer"
rm -rf /mnt/rd 2>/dev/null || true
rm -rf /mnt/media 2>/dev/null || true
rm -rf /var/cache/rclone 2>/dev/null || true
rm -rf /root/.config/rclone 2>/dev/null || true

# --- Undo installer tweak to fuse.conf ---
log "Reverting /etc/fuse.conf tweak (remove 'user_allow_other' if present)"
if [[ -f /etc/fuse.conf ]]; then
  # The installer appends this line if missing. Remove it (safe on a fresh install).
  sed -i '/^[[:space:]]*user_allow_other[[:space:]]*$/d' /etc/fuse.conf || true
fi

# --- Remove Docker runtime data (matches current reset behavior) ---
log "Removing Docker runtime data"
rm -rf /var/lib/docker 2>/dev/null || true
rm -rf /var/lib/containerd 2>/dev/null || true

# --- Remove Plex (installed by installer) ---
log "Removing Plex"
systemctl disable --now plexmediaserver 2>/dev/null || true
apt-get purge -y plexmediaserver 2>/dev/null || true
rm -f /etc/apt/sources.list.d/plex*.list 2>/dev/null || true
rm -f /etc/apt/sources.list.d/plexmediaserver*.list 2>/dev/null || true
rm -f /etc/apt/keyrings/plex.gpg 2>/dev/null || true
rm -f /usr/share/keyrings/plex.gpg 2>/dev/null || true

# --- Remove Docker CE packages + repo/key (installed by installer) ---
log "Removing Docker CE packages"
apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
apt-get purge -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
rm -f /etc/apt/sources.list.d/docker.list 2>/dev/null || true
rm -f /etc/apt/keyrings/docker.gpg 2>/dev/null || true

# --- Remove rclone (installer installs it) ---
log "Removing rclone"
apt-get purge -y rclone 2>/dev/null || true

log "Autoremove remaining dependencies"
apt-get autoremove -y 2>/dev/null || true

log "Reset complete"
echo "System is now in near pre-install state for this stack."
