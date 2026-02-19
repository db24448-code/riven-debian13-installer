#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 (trixie) - Riven + Zilean + Host Plex (VFS model, no rclone) - v22
#
# Installs/Configures:
# - Docker CE + docker compose plugin
# - Plex Media Server (host install via apt)
# - Zilean + Postgres (Docker)
# - Riven backend + frontend + Postgres (Docker) with RivenVFS enabled (FUSE)
# - systemd: riven-vfs-prepare.service + docker.service drop-in to guarantee mount propagation before containers start
#
# Architecture:
# RealDebrid -> Riven -> RivenVFS mount -> Host Plex
#
# Plex libraries MUST point to:
#   Movies: /opt/riven/vfs/movies
#   TV:     /opt/riven/vfs/shows
#
# Run as root:
#   sudo bash install_riven_stack_debian13_full_MATCHING_PORTS_v19_VFS.sh

############################
# Helpers
############################
log()  { printf "\n==> %s\n" "$*"; }
warn() { printf "\nWARN: %s\n" "$*" >&2; }
die()  { printf "\nERROR: %s\n" "$*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (or via sudo)."
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

rand_hex_32() {
  if have_cmd openssl; then
    openssl rand -hex 16
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
  fi
}

rand_secret() {
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
}

get_lan_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n1 || true)"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)"
  fi
  echo "${ip:-127.0.0.1}"
}

prompt() {
  local q="$1" def="${2:-}"
  local ans
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans
    echo "${ans:-$def}"
  else
    read -r -p "$q: " ans
    echo "$ans"
  fi
}

############################
# Docker install (CE repo)
############################
install_docker_if_needed() {
  log "Checking Docker + docker compose"
  if have_cmd docker && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker + docker compose already working; skipping Docker install"
    return 0
  fi

  log "Installing Docker CE + Compose plugin (official Docker repo)"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release iproute2 jq fuse3 openssl python3

  # remove Debian docker.io if present (avoid conflicts)
  apt-get remove -y docker.io docker-doc docker-compose podman-docker containerd runc >/dev/null 2>&1 || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
  docker info >/dev/null 2>&1 || die "Docker installed but 'docker info' failed."
  docker compose version >/dev/null 2>&1 || die "'docker compose' not working after install."
}

############################
# Plex repo + install
############################
install_plex() {
  log "Installing Plex Media Server (repo.plex.tv)"
  export DEBIAN_FRONTEND=noninteractive

  rm -f /etc/apt/sources.list.d/plex*.list /etc/apt/sources.list.d/plexmediaserver*.list 2>/dev/null || true
  rm -f /usr/share/keyrings/plex.gpg /etc/apt/keyrings/plex.gpg /etc/apt/keyrings/plex.asc 2>/dev/null || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.v2.key | gpg --dearmor -o /etc/apt/keyrings/plex.gpg
  chmod a+r /etc/apt/keyrings/plex.gpg

  echo "deb [signed-by=/etc/apt/keyrings/plex.gpg] https://repo.plex.tv/deb public main" \
    > /etc/apt/sources.list.d/plexmediaserver.list

  apt-get update -y
  apt-get install -y plexmediaserver
  systemctl enable --now plexmediaserver
}

############################
# Host mount propagation prep (required for VFS -> host Plex)
############################
prepare_riven_vfs_propagation() {
  log "Preparing host mount propagation for /opt/riven/vfs (rshared) + boot ordering"

  mkdir -p /opt/riven/vfs
  chmod 755 /opt/riven /opt/riven/vfs 2>/dev/null || true

  # Allow "allow_other" mounts if RivenVFS uses it (harmless if not used)
  if [[ -f /etc/fuse.conf ]] && ! grep -qE '^\s*user_allow_other\s*$' /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
  fi

  cat >/etc/systemd/system/riven-vfs-prepare.service <<'EOF'
[Unit]
Description=Prepare /opt/riven/vfs as a shared bind mount for RivenVFS propagation
DefaultDependencies=no
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -lc 'mkdir -p /opt/riven/vfs && mountpoint -q /opt/riven/vfs || mount --bind /opt/riven/vfs /opt/riven/vfs'
ExecStart=/bin/mount --make-rshared /opt/riven/vfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now riven-vfs-prepare.service

  # Ensure Docker waits for this (so restart policies don't race the propagation setup on boot)
  install -m 0755 -d /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/10-riven-vfs.conf <<'EOF'
[Unit]
Requires=riven-vfs-prepare.service
After=riven-vfs-prepare.service
EOF

  systemctl daemon-reload
  systemctl restart docker
}

############################
############################

############################
# Zilean + Postgres
############################
deploy_zilean() {
  log "Deploying Zilean + Postgres"
  mkdir -p /opt/zilean
  chmod 755 /opt/zilean

  local zilean_pg_pw
  zilean_pg_pw="$(rand_hex_32)"

  cat >/opt/zilean/docker-compose.yml <<EOF
services:
  postgres:
    image: postgres:17-alpine
    container_name: zilean-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: zilean
      POSTGRES_PASSWORD: ${zilean_pg_pw}
      POSTGRES_DB: zilean
    volumes:
      - zilean-pg-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zilean -d zilean"]
      interval: 10s
      timeout: 5s
      retries: 10

  zilean:
    image: ipromknight/zilean:latest
    container_name: zilean
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      TZ: Europe/London
      Zilean__Database__ConnectionString: Host=postgres;Port=5432;Database=zilean;Username=zilean;Password=${zilean_pg_pw}
      DATABASE_URL: postgresql://zilean:${zilean_pg_pw}@postgres:5432/zilean
    ports:
      - "0.0.0.0:8181:8181"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8181/healthchecks/ping >/dev/null 2>&1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s

volumes:
  zilean-pg-data:
EOF

  (cd /opt/zilean && docker compose pull postgres zilean)
  (cd /opt/zilean && docker compose up -d)
}

############################
# Riven stack
############################
deploy_riven() {
  log "Deploying Riven backend + frontend + Postgres (VFS model)"

  mkdir -p /opt/riven/data
  chmod 755 /opt/riven /opt/riven/data
  # Use a dedicated persistent directory for RivenVFS cache (disk-based; adjust if you prefer /dev/shm)
  mkdir -p /opt/riven/cache
  chmod 755 /opt/riven/cache

  local lan_ip default_lan backend_url origin backend_api_key pg_pw auth_secret
  default_lan="$(get_lan_ip)"
  lan_ip="$(prompt "LAN IP address for printed URLs / frontend ORIGIN" "$default_lan")"

  backend_api_key="$(prompt "Riven BACKEND_API_KEY (32 hex chars) - blank to auto-generate" "")"
  [[ -z "$backend_api_key" ]] && backend_api_key="$(rand_hex_32)"
  pg_pw="$(prompt "Riven Postgres password - blank to auto-generate" "")"
  [[ -z "$pg_pw" ]] && pg_pw="$(rand_hex_32)"
  auth_secret="$(prompt "Frontend AUTH_SECRET - blank to auto-generate" "")"
  [[ -z "$auth_secret" ]] && auth_secret="$(rand_secret)"

  backend_url="$(prompt "Backend URL used by frontend" "http://${lan_ip}:8080")"
  origin="$(prompt "Frontend ORIGIN" "http://${lan_ip}:3000")"
  # Optional: Plex token for Riven to trigger library refresh / updater
  local plex_token plex_url plex_enable
  plex_token="$(prompt "Plex token (optional; leave blank to disable Plex updater in Riven)" "")"
  # Determine a sensible default Plex URL for Linux hosts (no host.docker.internal on Debian by default)
  local host_ip default_plex_url
  host_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
  if [[ -z "${host_ip}" ]]; then
    host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  [[ -z "${host_ip}" ]] && host_ip="127.0.0.1"
  default_plex_url="http://${host_ip}:32400"
  plex_url="$(prompt "Plex URL (Riven container -> host Plex). Default uses host IP (${host_ip})" "${default_plex_url}")"
  if [[ -n "$plex_token" ]]; then plex_enable="true"; else plex_enable="false"; fi

  cat >/opt/riven/.env <<EOF
BACKEND_API_KEY=${backend_api_key}
POSTGRES_PASSWORD=${pg_pw}
AUTH_SECRET=${auth_secret}
BACKEND_URL=${backend_url}
ORIGIN=${origin}
PLEX_TOKEN=${plex_token}
PLEX_URL=${plex_url}
PLEX_UPDATER_ENABLED=${plex_enable}
EOF
  chmod 600 /opt/riven/.env

  cat >/opt/riven/docker-compose.yml <<'EOF'
services:
  riven-db:
    image: postgres:17-alpine
    container_name: riven-db
    restart: unless-stopped
    environment:
      PGDATA: /var/lib/postgresql/data/pgdata
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: riven
    volumes:
      - riven-pg-data:/var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 10

  riven:
    image: ghcr.io/rivenmedia/riven:latest
    container_name: riven
    restart: unless-stopped
    shm_size: 1024m
    ports:
      - "0.0.0.0:8080:8080"
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    devices:
      - /dev/fuse
    environment:
      TZ: Europe/London
      # Required for VFS (see Riven docs)
      RIVEN_FILESYSTEM_MOUNT_PATH: /mount
      # Cache tuning (adjust as desired; docs show /dev/shm for best performance)
      RIVEN_FILESYSTEM_CACHE_DIR: /cache
      RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB: "10240"
      # Backend auth + DB
      BACKEND_API_KEY: ${BACKEND_API_KEY}
      API_KEY: ${BACKEND_API_KEY}
      RIVEN_API_KEY: ${BACKEND_API_KEY}
      RIVEN_DATABASE_HOST: postgresql+psycopg2://postgres:${POSTGRES_PASSWORD}@riven-db:5432/riven
    volumes:
      - /opt/riven/data:/riven/data
      - /opt/riven/cache:/cache
      # This is the host-exposed path Plex will read
      - /opt/riven/vfs:/mount:rshared
    depends_on:
      riven-db:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/docs >/dev/null 2>&1"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 30s

  riven-frontend:
    image: ghcr.io/rivenmedia/riven-frontend:latest
    container_name: riven-frontend
    restart: unless-stopped
    ports:
      - "0.0.0.0:3000:3000"
    environment:
      TZ: Europe/London
      BACKEND_URL: ${BACKEND_URL}
      BACKEND_API_KEY: ${BACKEND_API_KEY}
      AUTH_SECRET: ${AUTH_SECRET}
      ORIGIN: ${ORIGIN}
    depends_on:
      riven:
        condition: service_healthy

volumes:
  riven-pg-data:
EOF

  # Seed Riven settings.json so Riven does not generate defaults that fail validation.
  # This sets:
  # - Scraping: Zilean enabled (http://zilean:8181)
  # - Updaters: Plex enabled if PLEX_TOKEN provided, using PLEX_URL (defaults to host IP)
  # - Downloaders: Real-Debrid enabled using the token you enter during install
  #
  # Riven's built-in downloader must be enabled or Riven will stall waiting for configuration and VFS will not mount
  # for Riven to fully start and mount VFS.
  local rd_token
  rd_token="$(prompt "Real-Debrid API token for Riven (https://real-debrid.com/apitoken)" "")"
  if [[ -z "$rd_token" ]]; then
    warn "No Real-Debrid token provided. Riven will likely stall waiting for a downloader and VFS will not mount."
    rd_token=""
  fi

  cat >/opt/riven/data/settings.json <<EOF_SETTINGS
{
  "version": "0.23.6",
  "api_key": "${backend_api_key}",
  "debug": true,
  "symlink": {
    "rclone_path": "/bin/true",
    "library_path": "/riven/data",
    "separate_anime_dirs": false,
    "repair_symlinks": false,
    "repair_interval": 6.0
  },
  "downloaders": {
    "real_debrid": {
      "enabled": %RD_ENABLED%,
      "api_key": "%RD_TOKEN%"
    }
  },
  "scraping": {
    "zilean": {
      "enabled": true,
      "url": "http://zilean:8181",
      "timeout": 30,
      "ratelimit": true
    }
  },
  "updaters": {
    "plex": {
      "enabled": %PLEX_ENABLED%,
      "token": "%PLEX_TOKEN%",
      "url": "%PLEX_URL%"
    }
  }
}
EOF_SETTINGS

  # Substitute booleans/tokens without leaking in shell history
  local rd_enabled plex_enabled
  if [[ -n "$rd_token" && "$rd_token" != "YOUR_RD_TOKEN" ]]; then rd_enabled="true"; else rd_enabled="false"; fi
  plex_enabled="${plex_enable}"

  sed -i \
    -e "s/%RD_ENABLED%/${rd_enabled}/g" \
    -e "s|%RD_TOKEN%|${rd_token}|g" \
    -e "s/%PLEX_ENABLED%/${plex_enabled}/g" \
    -e "s|%PLEX_TOKEN%|${plex_token}|g" \
    -e "s|%PLEX_URL%|${plex_url}|g" \
    /opt/riven/data/settings.json

  chmod 664 /opt/riven/data/settings.json || true

  (cd /opt/riven && docker compose --env-file .env pull)
  (cd /opt/riven && docker compose --env-file .env up -d)
}

############################
# Checks / summary
############################
post_checks() {
  log "Post-install checks"

  echo
  echo "Docker containers:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  echo

  echo "Mount propagation check (should be shared/rshared):"
  findmnt -T /opt/riven/vfs -o TARGET,PROPAGATION,FSTYPE 2>/dev/null || true
  echo

  if [ -d /opt/riven/vfs/movies ] && [ -d /opt/riven/vfs/shows ]; then
    echo "OK: VFS directories visible on host: /opt/riven/vfs/movies and /opt/riven/vfs/shows"
  else
    warn "VFS directories not visible on host yet."
    warn "Check Riven logs: docker logs riven | grep -i \"vfs\\|mount\\|fuse\""
  fi

  echo
  echo "Service endpoints (local checks):"
  curl -fsS --max-time 2 http://127.0.0.1:8080/docs >/dev/null 2>&1 && echo "OK: Riven backend :8080" || warn "Riven backend not reachable yet (docker logs riven)"
  curl -fsS --max-time 2 http://127.0.0.1:3000 >/dev/null 2>&1 && echo "OK: Riven frontend :3000" || warn "Riven frontend not reachable yet (docker logs riven-frontend)"
  curl -fsS --max-time 2 http://127.0.0.1:8181/healthchecks/ping >/dev/null 2>&1 && echo "OK: Zilean :8181" || warn "Zilean not reachable yet (cd /opt/zilean && docker compose logs --tail=200)"

  echo
  echo "Plex library paths (HOST):"
  echo "  Movies: /opt/riven/vfs/movies"
  echo "  TV:     /opt/riven/vfs/shows"
  echo
  echo "Riven UI:"
  echo "  http://<server-ip>:3000"
  echo
  echo "In Riven UI, configure integrations:"
  echo "  Zilean base URL: http://zilean:8181"
  echo
  echo "Reboot survival notes:"
  echo "  - riven-vfs-prepare.service runs before docker.service (via docker drop-in)"
  echo "  - Containers restart via restart: unless-stopped"
}

############################
# Main
############################
main() {
  need_root
  install_docker_if_needed
  install_plex
  prepare_riven_vfs_propagation
  deploy_zilean
  deploy_riven
  post_checks
}

main "$@"