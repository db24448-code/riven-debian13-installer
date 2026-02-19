#!/usr/bin/env bash
set -euo pipefail

# v24: Debian 13 (Trixie) - Riven VFS model (NO ZURG) + Zilean + host Plex
# Key fixes vs prior: shared external docker network so Riven can resolve "zilean"
#                    and deterministic Riven settings.json seeding.

LOG_PREFIX="==>"

log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "WARN: $*" >&2; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root (sudo)." >&2
    exit 1
  fi
}

rand_hex_32() {
  openssl rand -hex 16
}

ensure_pkg() {
  apt-get update -y
  apt-get install -y "$@"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    return 0
  fi
  log "Installing Docker Engine + Compose plugin (Debian)"
  ensure_pkg ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable"     >/etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

ensure_network() {
  local net="riven-net"
  if docker network inspect "$net" >/dev/null 2>&1; then
    log "Docker network '$net' exists"
  else
    log "Creating shared Docker network '$net'"
    docker network create "$net" >/dev/null
  fi
}

detect_host_ip() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip="$(ip route get 1.1.1.1 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  fi
  if [[ -z "${ip}" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${ip}"
}

install_plex_apt() {
  if systemctl list-unit-files | grep -q '^plexmediaserver\.service'; then
    log "Plex appears installed already (plexmediaserver.service found)"
    return 0
  fi
  log "Installing Plex Media Server (APT)"
  ensure_pkg curl gnupg
  curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor -o /usr/share/keyrings/plex.gpg
  echo "deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" >/etc/apt/sources.list.d/plexmediaserver.list
  apt-get update -y
  apt-get install -y plexmediaserver
  systemctl enable --now plexmediaserver
}

install_riven_vfs_prepare_service() {
  log "Installing riven-vfs-prepare.service"
  mkdir -p /opt/riven/vfs
  chmod 755 /opt/riven /opt/riven/vfs || true

  cat >/etc/systemd/system/riven-vfs-prepare.service <<'EOF'
[Unit]
Description=Prepare /opt/riven/vfs as a shared bind mount for RivenVFS propagation
Before=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash -lc 'mkdir -p /opt/riven/vfs; mount --bind /opt/riven/vfs /opt/riven/vfs; mount --make-rshared /opt/riven/vfs'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p /etc/systemd/system/docker.service.d
  cat >/etc/systemd/system/docker.service.d/10-riven-vfs-prepare.conf <<'EOF'
[Unit]
Requires=riven-vfs-prepare.service
After=riven-vfs-prepare.service
EOF

  systemctl daemon-reload
  systemctl enable --now riven-vfs-prepare.service
}

prompt_inputs() {
  log "Collecting required inputs"

  read -r -p "RealDebrid API token (required): " RD_TOKEN
  if [[ -z "${RD_TOKEN}" ]]; then
    echo "RealDebrid token is required for this Riven build to start VFS." >&2
    exit 1
  fi

  local host_ip
  host_ip="$(detect_host_ip)"
  if [[ -z "${host_ip}" ]]; then
    host_ip="127.0.0.1"
  fi

  read -r -p "Plex URL [default: http://${host_ip}:32400] (optional): " PLEX_URL
  PLEX_URL="${PLEX_URL:-http://${host_ip}:32400}"

  read -r -p "Plex token (optional, leave blank to disable Plex updater): " PLEX_TOKEN
}

write_env_files() {
  mkdir -p /opt/riven
  chmod 755 /opt/riven

  if [[ ! -f /opt/riven/.env ]]; then
    local pg_pw backend_key auth_secret
    pg_pw="$(rand_hex_32)"
    backend_key="$(rand_hex_32)"
    auth_secret="$(rand_hex_32)"
    cat >/opt/riven/.env <<EOF
POSTGRES_PASSWORD=${pg_pw}
BACKEND_API_KEY=${backend_key}
BACKEND_URL=http://riven:8080
AUTH_SECRET=${auth_secret}
ORIGIN=http://localhost:3000
EOF
    chmod 600 /opt/riven/.env
  fi
}

seed_riven_settings() {
  mkdir -p /opt/riven/data
  chmod 755 /opt/riven/data
  local backend_key
  backend_key="$(. /opt/riven/.env && echo "${BACKEND_API_KEY}")"

  log "Writing /opt/riven/data/settings.json (VFS + Zilean + optional Plex updater)"
  if [[ -n "${PLEX_TOKEN}" ]]; then
    cat >/opt/riven/data/settings.json <<EOF
{
  "version": "0.23.6",
  "api_key": "${backend_key}",
  "debug": true,
  "symlink": {
    "rclone_path": "/bin/true",
    "library_path": "/riven/data",
    "separate_anime_dirs": false,
    "repair_symlinks": false,
    "repair_interval": 6.0
  },
  "downloaders": {
    "real_debrid": { "enabled": true, "api_key": "${RD_TOKEN}" }
  },
  "scraping": {
    "zilean": { "enabled": true, "url": "http://zilean:8181", "timeout": 30, "ratelimit": true }
  },
  "updaters": {
    "plex": { "enabled": true, "token": "${PLEX_TOKEN}", "url": "${PLEX_URL}" }
  }
}
EOF
  else
    cat >/opt/riven/data/settings.json <<EOF
{
  "version": "0.23.6",
  "api_key": "${backend_key}",
  "debug": true,
  "symlink": {
    "rclone_path": "/bin/true",
    "library_path": "/riven/data",
    "separate_anime_dirs": false,
    "repair_symlinks": false,
    "repair_interval": 6.0
  },
  "downloaders": {
    "real_debrid": { "enabled": true, "api_key": "${RD_TOKEN}" }
  },
  "scraping": {
    "zilean": { "enabled": true, "url": "http://zilean:8181", "timeout": 30, "ratelimit": true }
  },
  "updaters": {
    "plex": { "enabled": false, "token": "", "url": "http://localhost:32400" }
  }
}
EOF
  fi
  chmod 664 /opt/riven/data/settings.json || true
}

deploy_zilean() {
  log "Deploying Zilean stack (shared network: riven-net)"
  mkdir -p /opt/zilean
  chmod 755 /opt/zilean

  if [[ -f /opt/zilean/.env ]]; then
    . /opt/zilean/.env || true
  fi
  if [[ -z "${ZILEAN_POSTGRES_PASSWORD:-}" ]]; then
    ZILEAN_POSTGRES_PASSWORD="$(rand_hex_32)"
    echo "ZILEAN_POSTGRES_PASSWORD=${ZILEAN_POSTGRES_PASSWORD}" >/opt/zilean/.env
    chmod 600 /opt/zilean/.env
  fi

  cat >/opt/zilean/docker-compose.yml <<'EOF'
services:
  zilean-db:
    image: postgres:17-alpine
    container_name: zilean-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: zilean
      POSTGRES_PASSWORD: ${ZILEAN_POSTGRES_PASSWORD}
      POSTGRES_DB: zilean
    volumes:
      - zilean-pg-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U zilean -d zilean"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks:
      - riven-net

  zilean:
    image: ipromknight/zilean:latest
    container_name: zilean
    restart: unless-stopped
    ports:
      - "0.0.0.0:8181:8181"
    environment:
      Zilean__Database__ConnectionString: Host=zilean-db;Port=5432;Database=zilean;Username=zilean;Password=${ZILEAN_POSTGRES_PASSWORD}
      DATABASE_URL: postgresql://zilean:${ZILEAN_POSTGRES_PASSWORD}@zilean-db:5432/zilean
    depends_on:
      zilean-db:
        condition: service_healthy
    networks:
      - riven-net

networks:
  riven-net:
    external: true

volumes:
  zilean-pg-data:
EOF

  (cd /opt/zilean && docker compose pull)
  (cd /opt/zilean && docker compose up -d)
}

deploy_riven_stack() {
  log "Deploying Riven stack (shared network: riven-net)"
  mkdir -p /opt/riven/cache /opt/riven/vfs
  chmod 755 /opt/riven /opt/riven/cache /opt/riven/vfs || true

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
    networks:
      - riven-net

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
      RIVEN_FILESYSTEM_MOUNT_PATH: /mount
      RIVEN_FILESYSTEM_CACHE_DIR: /cache
      RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB: "10240"
      BACKEND_API_KEY: ${BACKEND_API_KEY}
      API_KEY: ${BACKEND_API_KEY}
      RIVEN_API_KEY: ${BACKEND_API_KEY}
      RIVEN_DATABASE_HOST: postgresql+psycopg2://postgres:${POSTGRES_PASSWORD}@riven-db:5432/riven
    volumes:
      - /opt/riven/data:/riven/data
      - /opt/riven/cache:/cache
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
    networks:
      - riven-net

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
    networks:
      - riven-net

networks:
  riven-net:
    external: true

volumes:
  riven-pg-data:
EOF

  (cd /opt/riven && docker compose pull)
  (cd /opt/riven && docker compose up -d)
}

post_checks() {
  log "Post-checks"

  if curl -fsS --max-time 2 http://127.0.0.1:8181/healthchecks/ping >/dev/null 2>&1; then
    echo "OK: Zilean :8181"
  else
    warn "Zilean not reachable yet (cd /opt/zilean && docker compose logs --tail=200 zilean)"
  fi

  if curl -fsS --max-time 2 http://127.0.0.1:8080/docs >/dev/null 2>&1; then
    echo "OK: Riven :8080"
  else
    warn "Riven not reachable yet (docker logs riven)"
  fi

  if curl -fsS --max-time 2 http://127.0.0.1:3000 >/dev/null 2>&1; then
    echo "OK: Riven Frontend :3000"
  else
    warn "Riven frontend not reachable yet (docker logs riven-frontend)"
  fi

  if [[ -d /opt/riven/vfs ]] && [[ -z "$(ls -A /opt/riven/vfs 2>/dev/null || true)" ]]; then
    warn "VFS directories not visible on host yet."
    warn 'Check Riven logs: docker logs riven | grep -i "filesystem\|vfs\|mount\|fuse"'
  fi

  echo
  echo "Plex library paths:"
  echo "  Movies: /opt/riven/vfs/movies"
  echo "  TV:     /opt/riven/vfs/shows"
}

main() {
  need_root
  ensure_pkg jq wget openssl
  ensure_docker
  ensure_network
  install_plex_apt
  install_riven_vfs_prepare_service
  prompt_inputs
  write_env_files
  seed_riven_settings
  deploy_zilean
  deploy_riven_stack
  post_checks
}

main "$@"
