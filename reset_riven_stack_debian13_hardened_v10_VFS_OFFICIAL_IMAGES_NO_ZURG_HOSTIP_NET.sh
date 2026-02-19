#!/usr/bin/env bash
set -euo pipefail

# v10: Reset for Debian 13 Riven VFS (NO ZURG) + Zilean + host Plex

LOG_PREFIX="==>"

log()  { echo "${LOG_PREFIX} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

stop_compose_if_present() {
  local dir="$1"
  if [[ -d "$dir" && -f "$dir/docker-compose.yml" ]]; then
    (cd "$dir" && docker compose down --remove-orphans --volumes) || true
  fi
}

main() {
  need_root

  log "Stopping stacks (if present)"
  stop_compose_if_present /opt/riven
  stop_compose_if_present /opt/zilean

  log "Force removing known containers (ignore errors)"
  for c in riven riven-db riven-frontend zilean zilean-db zurg; do
    docker rm -f "$c" 2>/dev/null || true
  done

  log "Disabling + removing riven-vfs-prepare.service"
  systemctl disable --now riven-vfs-prepare.service 2>/dev/null || true
  rm -f /etc/systemd/system/riven-vfs-prepare.service

  rm -f /etc/systemd/system/docker.service.d/10-riven-vfs-prepare.conf
  rmdir /etc/systemd/system/docker.service.d 2>/dev/null || true

  systemctl daemon-reload
  systemctl restart docker || true

  log "Unmounting VFS (host)"
  umount -l /opt/riven/vfs 2>/dev/null || true

  log "Removing data directories"
  rm -rf /opt/riven /opt/zilean /opt/zurg || true

  log "Removing shared docker network (riven-net)"
  docker network rm riven-net 2>/dev/null || true

  log "Done. System reset complete."
}

main "$@"
