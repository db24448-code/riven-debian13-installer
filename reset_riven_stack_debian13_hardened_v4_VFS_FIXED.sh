#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 - Full Riven/Zilean/Zurg Stack Reset (hardened v4, VFS model, no rclone)
# WARNING: Destructive. Intended for test boxes to return to a clean pre-install state.
#
# Removes:
# - systemd: riven-vfs-prepare.service + docker.service drop-in
# - VFS mountpoint: /opt/riven/vfs (unmount if present)
# - stack dirs: /opt/riven /opt/zurg /opt/zilean
# - Docker resources: compose projects, containers, networks, volumes, images
# - Packages/repos (optional): Plex, Docker CE repo/key
#
# Usage:
#   sudo ./reset_riven_stack_debian13_hardened_v4_VFS.sh
# Optional:
#   sudo ./reset_riven_stack_debian13_hardened_v4_VFS.sh --keep-packages   # keep docker/plex installed

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

# --- Stop systemd services created by installer (so mounts can be released) ---
log "Stopping systemd services created by installer"
systemctl stop riven-vfs-prepare.service 2>/dev/null || true

# --- Remove docker.service drop-in that enforces ordering ---
log "Removing docker.service drop-in (if present)"
rm -f /etc/systemd/system/docker.service.d/10-riven-vfs.conf 2>/dev/null || true
rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true

# --- Unmount VFS mountpoint (best-effort) ---
log "Unmounting /opt/riven/vfs (best-effort)"
command -v fusermount3 >/dev/null 2>&1 && fusermount3 -uz /opt/riven/vfs 2>/dev/null || true
command -v fusermount  >/dev/null 2>&1 && fusermount  -uz /opt/riven/vfs 2>/dev/null || true
if findmnt -rn /opt/riven/vfs >/dev/null 2>&1; then
  umount -lR /opt/riven/vfs 2>/dev/null || umount -l /opt/riven/vfs 2>/dev/null || true
fi

# --- Disable/remove systemd unit file ---
log "Disabling + removing riven-vfs-prepare.service"
systemctl disable riven-vfs-prepare.service 2>/dev/null || true
rm -f /etc/systemd/system/riven-vfs-prepare.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# --- Docker teardown ---
if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    log "Starting Docker temporarily for cleanup"
    systemctl start docker 2>/dev/null || true
    sleep 1
  fi

  if docker info >/dev/null 2>&1; then
    if [[ -f /opt/riven/docker-compose.yml ]]; then
      log "docker compose down (Riven)"
      (cd /opt/riven && docker compose --env-file .env down --remove-orphans --volumes) 2>/dev/null || true
    fi
    if [[ -f /opt/zilean/docker-compose.yml ]]; then
      log "docker compose down (Zilean)"
      (cd /opt/zilean && docker compose down --remove-orphans --volumes) 2>/dev/null || true
    fi

    log "Removing stack containers (best-effort)"
    for c in riven riven-db riven-frontend zurg zilean zilean-db postgres riven-riven-1 riven-riven-db-1 riven-riven-frontend-1 riven-zurg-1 zilean-zilean-1 zilean-postgres-1; do
      docker rm -f "$c" 2>/dev/null || true
    done

    log "Docker prune (images/containers/networks/volumes not in use)"
    docker system prune -af --volumes 2>/dev/null || true

    log "Removing known stack networks (best-effort)"
    for net in riven_default zilean_default media-net zilean-net; do
      docker network rm "$net" 2>/dev/null || true
    done
  else
    warn "Docker daemon not reachable; skipped docker cleanup commands."
  fi

  log "Stopping Docker service"
  systemctl stop docker 2>/dev/null || true
fi

# --- Remove stack directories and data paths ---
log "Removing stack directories and data"
rm -rf /opt/riven /opt/zurg /opt/zilean 2>/dev/null || true
rm -rf /opt/riven/vfs 2>/dev/null || true

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

  log "Autoremove leftover dependencies"
  apt-get autoremove -y 2>/dev/null || true
else
  log "Keeping installed packages (Docker/Plex) because --keep-packages was set"
fi

log "Reset complete"
echo "Clean-state reset finished."
echo "Tip: if you want to keep Docker/Plex installed between tests, run with: --keep-packages"
