#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 (trixie) "Riven stack" installer - LAN-accessible
# Installs: Docker CE + compose, Plex, Zurg, rclone mount, Zilean+Postgres, Riven backend+frontend+Postgres
#
# Run as root:
#   bash install_riven_stack_debian13_full_REVISED_v6.sh
#
# Notes:
# - Designed for minimal Debian 13 where sudo may not exist.
# - Binds web UIs to LAN (0.0.0.0). Use a firewall if you don't want broad access.

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
  # 32 hex chars
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
  # long URL-safe secret
  python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
}

get_lan_ip() {
  # Best-effort first non-loopback IPv4
  local ip
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n1 || true)"
  if [[ -z "$ip" ]]; then
    ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}' || true)"
  fi
  echo "${ip:-127.0.0.1}"
}

retry() {
  # retry <attempts> <sleep_seconds> -- <cmd...>
  local attempts="$1"; shift
  local sleep_s="$1"; shift
  [[ "$1" == "--" ]] && shift
  local i=1
  until "$@"; do
    if (( i >= attempts )); then
      return 1
    fi
    sleep "$sleep_s"
    ((i++))
  done
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
  apt-get install -y ca-certificates curl gnupg lsb-release iproute2 jq fuse3 python3 python3-venv python3-pip openssl

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

  # Validate
  docker info >/dev/null 2>&1 || die "Docker installed but 'docker info' failed. Check systemctl status docker."
  docker compose version >/dev/null 2>&1 || die "'docker compose' not working after install."
}

############################
# Plex repo (new v2 key) + install
############################
install_plex() {
  log "Installing Plex Media Server (repo.plex.tv + PlexSign.v2.key)"

  # Remove legacy Plex repo files/keys that break apt on Debian 13 (SHA1 rejection)
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
# Zurg + rclone mount
############################
deploy_zurg_and_rclone() {
  log "Deploying Zurg container"
  mkdir -p /opt/zurg/{config,data}
  chmod 700 /opt/zurg/config
  chmod 755 /opt/zurg/data

  if [[ ! -f /opt/zurg/config/config.yml ]]; then
    cat >/opt/zurg/config/config.yml <<'EOF'
# Zurg config placeholder.
# You MUST edit this and add your Real-Debrid token + settings.
# See Zurg docs.
EOF
    chmod 600 /opt/zurg/config/config.yml
    warn "Created /opt/zurg/config/config.yml placeholder. You must configure Zurg (Real-Debrid token) for full functionality."
  fi

  docker rm -f zurg >/dev/null 2>&1 || true
  docker run -d --name zurg \
    --restart unless-stopped \
    -p 9999:9999 \
    -v /opt/zurg/config:/app/config:ro \
    -v /opt/zurg/data:/app/data \
    ghcr.io/debridmediamanager/zurg-testing:latest >/dev/null

  log "Installing rclone (Debian repo)"
  apt-get install -y rclone

  log "Configuring rclone mount service (WebDAV -> /mnt/rd)"
  mkdir -p /mnt/rd /var/cache/rclone
  chmod 755 /mnt/rd
  chmod 755 /var/cache/rclone

  # allow other users
  if ! grep -qE '^\s*user_allow_other\s*$' /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
  fi

  # Create rclone remote placeholder if missing
  mkdir -p /root/.config/rclone
  if [[ ! -f /root/.config/rclone/rclone.conf ]]; then
    cat >/root/.config/rclone/rclone.conf <<'EOF'
# rclone config placeholder.
# You MUST configure a WebDAV remote that points at Zurg.
# Example remote name: zurg
EOF
    chmod 600 /root/.config/rclone/rclone.conf
    warn "Created /root/.config/rclone/rclone.conf placeholder. You must configure rclone remote 'zurg' to point at Zurg WebDAV."
  fi

  cat >/etc/systemd/system/rclone-zurg.service <<'EOF'
[Unit]
Description=Rclone mount: Zurg WebDAV -> /mnt/rd
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/bin/rclone mount zurg: /mnt/rd \
  --config=/root/.config/rclone/rclone.conf \
  --allow-other \
  --dir-cache-time=2h \
  --vfs-cache-mode=full \
  --vfs-cache-max-size=50G \
  --vfs-cache-max-age=24h \
  --cache-dir=/var/cache/rclone \
  --poll-interval=15s \
  --timeout=1h \
  --umask=002 \
  --log-level=INFO
ExecStop=/bin/fusermount3 -uz /mnt/rd
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now rclone-zurg.service
}

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
  zilean-db:
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
      zilean-db:
        condition: service_healthy
    environment:
      TZ: Europe/London
      DATABASE_URL: postgresql://zilean:${zilean_pg_pw}@zilean-db:5432/zilean
    ports:
      - "0.0.0.0:8181:8181"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8181/healthchecks/ping >/dev/null 2>&1"]
      interval: 10s
      timeout: 5s
      retries: 20

volumes:
  zilean-pg-data:
EOF

  (cd /opt/zilean && docker compose up -d)
}

############################
# Riven stack (backend + frontend + db) + mount prep
############################
deploy_riven() {
  log "Preparing mount propagation for /opt/riven/vfs (rshared)"
  mkdir -p /opt/riven/vfs
  cat >/etc/systemd/system/riven-vfs-prepare.service <<'EOF'
[Unit]
Description=Prepare /opt/riven/vfs as a shared bind mount for rshared propagation
Before=docker.service
RequiresMountsFor=/opt/riven

[Service]
Type=oneshot
ExecStart=/bin/mount --bind /opt/riven/vfs /opt/riven/vfs
ExecStart=/bin/mount --make-rshared /opt/riven/vfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now riven-vfs-prepare.service

  log "Deploying Riven backend + frontend + Postgres (LAN accessible)"
  mkdir -p /opt/riven
  chmod 755 /opt/riven
  mkdir -p /opt/riven/data/logs
  # Riven container runs as 1000:1000
  chown -R 1000:1000 /opt/riven/data
  chmod -R u+rwX,g+rwX /opt/riven/data

  mkdir -p /mnt/media
  chmod 755 /mnt/media

  local lan_ip riven_api_key pg_pw auth_secret
  lan_ip="$(get_lan_ip)"
  riven_api_key="$(rand_hex_32)"
  pg_pw="$(rand_hex_32)"
  auth_secret="$(rand_secret)"

  # Write env file for frontend substitutions
  cat >/opt/riven/.env <<EOF
# Riven compose variables
RIVEN_API_KEY=${riven_api_key}
POSTGRES_PASSWORD=${pg_pw}

# Frontend wiring (LAN)
BACKEND_URL=http://${lan_ip}:18080
BACKEND_API_KEY=${riven_api_key}
AUTH_SECRET=${auth_secret}
ORIGIN=http://${lan_ip}:3000
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
    image: spoked/riven:dev
    container_name: riven
    restart: unless-stopped
    shm_size: 1024m
    ports:
      - "0.0.0.0:18080:8080"
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    devices:
      - /dev/fuse
    environment:
      TZ: Europe/London
      RIVEN_FORCE_ENV: "true"
      RIVEN_API_KEY: ${RIVEN_API_KEY}
      RIVEN_DATABASE_HOST: postgresql+psycopg2://postgres:${POSTGRES_PASSWORD}@riven-db:5432/riven
      RIVEN_FILESYSTEM_MOUNT_PATH: /mount
      RIVEN_UPDATERS_LIBRARY_PATH: /library
    volumes:
      - ./data:/riven/data
      - /opt/riven/vfs:/mount:rshared
      - /mnt/rd:/debrid:rshared
      - /mnt/media:/library:rshared
    depends_on:
      riven-db:
        condition: service_healthy
    healthcheck:
      # Use IPv4; localhost may resolve to ::1 and fail
      test: ["CMD-SHELL", "wget -qO- http://127.0.0.1:8080/docs >/dev/null 2>&1"]
      interval: 15s
      timeout: 5s
      retries: 20
      start_period: 30s

  riven-frontend:
    image: spoked/riven-frontend:dev
    container_name: riven-frontend
    restart: unless-stopped
    ports:
      - "0.0.0.0:3000:3000"
    environment:
      TZ: Europe/London
      DATABASE_URL: /riven/data/riven.db
      BACKEND_URL: ${BACKEND_URL}
      BACKEND_API_KEY: ${BACKEND_API_KEY}
      AUTH_SECRET: ${AUTH_SECRET}
      ORIGIN: ${ORIGIN}
    volumes:
      - riven-frontend-data:/riven/data
    depends_on:
      riven:
        condition: service_healthy

volumes:
  riven-frontend-data:
  riven-pg-data:
EOF

  (cd /opt/riven && docker compose --env-file .env up -d)
}

############################
# Post-install checks
############################
post_checks() {
  log "Post-install checks"

  log "systemd: docker, plex, rclone mount, vfs prepare"
  systemctl is-active --quiet docker || die "docker service not active"
  systemctl is-active --quiet riven-vfs-prepare.service || die "riven-vfs-prepare.service not active"
  systemctl is-active --quiet rclone-zurg.service || warn "rclone-zurg.service not active (Zurg/rclone may not be configured yet)"
  systemctl is-active --quiet plexmediaserver || warn "plexmediaserver not active"

  log "Mount propagation (/opt/riven/vfs)"
  if have_cmd findmnt; then
    local prop
    prop="$(findmnt -no PROPAGATION /opt/riven/vfs 2>/dev/null || true)"
    echo "Propagation: ${prop:-unknown}"
    [[ "${prop}" == *shared* ]] || warn "Mount propagation is not shared. Riven VFS may misbehave. Check riven-vfs-prepare.service"
  fi

  log "Zurg UI (best-effort)"
  if retry 10 2 -- curl -fsS http://127.0.0.1:9999/ >/dev/null 2>&1; then
    echo "OK: Zurg UI reachable on http://$(get_lan_ip):9999/"
  else
    warn "Zurg UI not reachable on localhost:9999 (container may still be starting or config incomplete)"
  fi

  log "Rclone mount (best-effort)"
  if mount | grep -q 'on /mnt/rd type fuse.rclone'; then
    echo "OK: /mnt/rd is mounted"
  else
    warn "/mnt/rd not mounted yet. Ensure rclone remote 'zurg' is configured and service is running."
  fi

  log "Zilean health (best-effort)"
  if retry 30 2 -- curl -fsS http://127.0.0.1:8181/healthchecks/ping >/dev/null 2>&1; then
    echo "OK: Zilean healthy on http://$(get_lan_ip):8181/"
  else
    warn "Zilean not healthy yet (check: docker logs zilean)"
  fi

  log "Riven backend health"
  if retry 40 2 -- curl -fsS http://127.0.0.1:18080/docs >/dev/null 2>&1; then
    echo "OK: Riven backend reachable on http://$(get_lan_ip):18080/docs"
  else
    warn "Riven backend not reachable. Showing logs:"
    (cd /opt/riven && docker compose --env-file .env ps) || true
    (cd /opt/riven && docker compose --env-file .env logs --tail=200 riven) || true
    die "Riven backend check failed."
  fi

  log "Riven container: write test to /library"
  if docker exec -it riven sh -lc 'touch /library/_riven_write_test && rm -f /library/_riven_write_test' >/dev/null 2>&1; then
    echo "OK: Riven can write to /library (host /mnt/media)"
  else
    warn "Riven cannot write to /library. Check /mnt/media permissions and mount."
  fi

  echo ""
  echo "============================"
  echo "LAN URLs"
  echo "  Plex:          http://$(get_lan_ip):32400/web"
  echo "  Zurg:          http://$(get_lan_ip):9999/"
  echo "  Zilean:        http://$(get_lan_ip):8181/"
  echo "  Riven backend: http://$(get_lan_ip):18080/docs"
  echo "  Riven UI:      http://$(get_lan_ip):3000"
  echo "============================"
  echo ""
  warn "You still need to complete some UI steps: Plex claim/token, Zurg token/config, Riven enable downloader/scraper/updater."
}

############################
# Main
############################
main() {
  need_root
  log "Installing base packages + Docker"
  install_docker_if_needed

  log "Installing Plex"
  install_plex

  log "Deploying Zurg + rclone"
  deploy_zurg_and_rclone

  log "Deploying Zilean"
  deploy_zilean

  log "Deploying Riven"
  deploy_riven

  post_checks
}

main "$@"
