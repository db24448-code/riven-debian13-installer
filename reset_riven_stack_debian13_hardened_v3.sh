#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 - Full Riven/Zilean/Zurg Stack Reset (hardened v3)
# WARNING: Destructive. Intended for test boxes to return to a clean pre-install state.
#
# Covers changes made by install_riven_stack_debian13_full_MATCHING_PORTS_v12.sh (and later v13+ / v16+ / v17+):
# - systemd units: rclone-zurg.service, riven-vfs-prepare.service
# - mounts: /mnt/rd and /opt/riven/vfs
# - stack dirs: /opt/riven /opt/zurg /opt/zilean
# - media/cache dirs: /mnt/media, /var/cache/rclone, /root/.config/rclone
# - fuse.conf tweak: user_allow_other
# - Docker resources: compose projects, containers, networks, volumes, images
# - Packages/repos: Plex, Docker CE repo/key, rclone (optional but default ON)
#
# Usage:
#   sudo ./reset_riven_stack_debian13_hardened_v2.sh
# Optional:
#   sudo ./reset_riven_stack_debian13_hardened_v2.sh --keep-packages   # keep docker/plex/rclone installed

KEEP_PACKAGES=0
if [[ "${1:-}" == "--keep-packages" ]]; then
  KEEP_PACKAGES=1
fi

log(){ printf "\n==> %s\n" "$*"; }
warn(){ printf "\nWARN: %s\n" "$*" >&2; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: Run as root (sudo -i or su -)."
    exit 1
  fi
}
need_root

export DEBIAN_FRONTEND=noninteractive

# --- Stop systemd services created by installer (stop first, unmount, then disable/remove) ---
log "Stopping systemd services created by installer (so mounts can be released)"
systemctl stop rclone-zurg.service 2>/dev/null || true
systemctl stop riven-vfs-prepare.service 2>/dev/null || true

# --- Unmount anything the installer mounted/bound ---
log "Unmounting mount points (best-effort)"
# Unmount VFS bind/mount first, then the rclone mount
if findmnt -rn /opt/riven/vfs >/dev/null 2>&1; then
  umount -lR /opt/riven/vfs 2>/dev/null || umount -l /opt/riven/vfs 2>/dev/null || true
fi
if findmnt -rn /mnt/rd >/dev/null 2>&1; then
  umount -lR /mnt/rd 2>/dev/null || umount -l /mnt/rd 2>/dev/null || true
fi

# --- Disable/remove systemd units created by installer ---
log "Disabling + removing systemd unit files created by installer"
systemctl disable rclone-zurg.service 2>/dev/null || true
systemctl disable riven-vfs-prepare.service 2>/dev/null || true
rm -f /etc/systemd/system/rclone-zurg.service /etc/systemd/system/riven-vfs-prepare.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

log "Unmounting mount points (best-effort)"
umount -lR /mnt/rd 2>/dev/null || true
umount -lR /opt/riven/vfs 2>/dev/null || true

# --- Docker teardown ---
if command -v docker >/dev/null 2>&1; then
  # Ensure daemon is running for cleanup (avoid "cannot connect to the Docker daemon" spam)
  if ! docker info >/dev/null 2>&1; then
    log "Starting Docker temporarily for cleanup"
    systemctl start docker 2>/dev/null || true
    sleep 1
  fi

  if docker info >/dev/null 2>&1; then
    # Bring down compose projects cleanly if their directories still exist
    if [[ -f /opt/riven/docker-compose.yml ]]; then
      log "docker compose down (Riven)"
      (cd /opt/riven && docker compose --env-file .env down --remove-orphans --volumes) 2>/dev/null || true
    fi
    if [[ -f /opt/zurg/docker-compose.yml ]]; then
      log "docker compose down (Zurg)"
      (cd /opt/zurg && docker compose down --remove-orphans --volumes) 2>/dev/null || true
    fi
    if [[ -f /opt/zilean/docker-compose.yml ]]; then
      log "docker compose down (Zilean)"
      (cd /opt/zilean && docker compose down --remove-orphans --volumes) 2>/dev/null || true
    fi

    # Stop/remove known containers (covers container_name use as well as compose default naming)
    log "Removing stack containers (best-effort)"
    for c in riven riven-db riven-frontend zurg zilean zilean-db postgres riven-riven-1 riven-riven-db-1 riven-riven-frontend-1 riven-zurg-1 zilean-zilean-1 zilean-postgres-1; do
      docker rm -f "$c" 2>/dev/null || true
    done

    # Clean remaining docker resources created by the stack.
    # This is the cleanest "test reset" approach: remove unused objects including volumes.
    log "Docker prune (images/containers/networks/volumes not in use)"
    docker system prune -af --volumes 2>/dev/null || true

    # Remove specific networks if they survived (rare if compose dirs were deleted early)
    log "Removing known stack networks (best-effort)"
    for net in riven_default zilean_default zurg_default zilean-net media-net; do
      docker network rm "$net" 2>/dev/null || true
    done
  else
    warn "Docker daemon not reachable; skipped docker cleanup commands."
  fi

  # Stop docker (if you want it off between tests)
  log "Stopping Docker service"
  systemctl stop docker 2>/dev/null || true
fi

# --- Remove stack directories and data paths created by installer ---
log "Removing stack directories and data"
rm -rf /opt/riven /opt/zurg /opt/zilean 2>/dev/null || true
rm -rf /opt/riven/vfs 2>/dev/null || true
rm -rf /mnt/rd /mnt/media 2>/dev/null || true
rm -rf /var/cache/rclone /root/.config/rclone 2>/dev/null || true

# --- Undo installer tweak to fuse.conf ---
log "Reverting /etc/fuse.conf tweak (remove 'user_allow_other' if present)"
if [[ -f /etc/fuse.conf ]]; then
  sed -i '/^[[:space:]]*user_allow_other[[:space:]]*$/d' /etc/fuse.conf 2>/dev/null || true
fi

# --- Remove Docker runtime data (only if we are doing a full package reset) ---
if [[ "$KEEP_PACKAGES" -eq 0 ]]; then
  log "Removing Docker runtime data (/var/lib/docker, /var/lib/containerd)"
  rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true
fi

# --- Remove packages/repos installed by installer ---
if [[ "$KEEP_PACKAGES" -eq 0 ]]; then
  log "Removing Plex (package + repo/key)"
  systemctl disable --now plexmediaserver 2>/dev/null || true
  apt-get purge -y plexmediaserver 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/plex*.list /etc/apt/sources.list.d/plexmediaserver*.list 2>/dev/null || true
  rm -f /etc/apt/keyrings/plex.gpg /usr/share/keyrings/plex.gpg 2>/dev/null || true

  log "Removing Docker packages + repo/key"
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  apt-get purge -y docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
  rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg 2>/dev/null || true

  log "Removing rclone"
  apt-get purge -y rclone 2>/dev/null || true

  log "Autoremove leftover dependencies"
  apt-get autoremove -y 2>/dev/null || true
else
  log "Keeping installed packages (Docker/Plex/rclone) because --keep-packages was set"
fi

log "Reset complete"
echo "Clean-state reset finished."
echo "Tip: if you want to keep Docker/Plex/rclone installed between tests, run with: --keep-packages"
