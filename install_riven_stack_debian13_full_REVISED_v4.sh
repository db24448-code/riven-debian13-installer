#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---------------------------
# Configurable defaults
# Override by exporting before running the script, e.g.:
#   BIND_ADDR=0.0.0.0 ./install_riven_stack_debian13_full.sh
# ---------------------------
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"   # 127.0.0.1 = local-only; 0.0.0.0 = all interfaces
RCLONE_VFS_CACHE_MAX_SIZE="${RCLONE_VFS_CACHE_MAX_SIZE:-50G}"
RCLONE_VFS_CACHE_MAX_AGE="${RCLONE_VFS_CACHE_MAX_AGE:-24h}"
RCLONE_DIR_CACHE_TIME="${RCLONE_DIR_CACHE_TIME:-2m}"

# Debian 13 full installer for:
# Plex + Zurg + rclone mount + Zilean + Riven (backend/frontend/db)
#
# IMPORTANT:
# - This script installs packages and creates systemd units.
# - It prompts for secrets (Real-Debrid token, API keys, passwords).
# - Re-run safe: it will not delete data directories unless you choose to.
#
# Run as root:
#   sudo bash install_riven_stack_debian13_full.sh

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash "$0""
  exit 1
fi

log() { echo -e "\n==> $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

prompt_secret() {
  local varname="$1"
  local prompt="$2"
  local value
  read -r -s -p "$prompt" value
  echo
  if [[ -z "$value" ]]; then
    echo "Value cannot be empty."
    exit 1
  fi
  printf -v "$varname" '%s' "$value"
}

prompt_value() {
  local varname="$1"
  local prompt="$2"
  local default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value
  fi
  if [[ -z "$value" ]]; then
    echo "Value cannot be empty."
    exit 1
  fi
  printf -v "$varname" '%s' "$value"
}

log "Collecting inputs"
prompt_value SERVER_IP "Enter your server LAN IP (used for ORIGIN and service URLs)" "127.0.0.1"
prompt_secret RD_TOKEN "Enter your Real-Debrid token (hidden input): "
prompt_value RIVEN_API_KEY "Enter a 32-character Riven API key (or type 'gen' to generate)" "gen"
if [[ "$RIVEN_API_KEY" == "gen" ]]; then
  RIVEN_API_KEY="$(openssl rand -hex 16)"
  log "Generated Riven API key and stored in /opt/riven/.env"
fi
if [[ "${#RIVEN_API_KEY}" -ne 32 ]]; then
  echo "RIVEN_API_KEY must be exactly 32 characters. Got length ${#RIVEN_API_KEY}."
  exit 1
fi

prompt_value AUTH_SECRET "Enter an AUTH_SECRET for Riven frontend (or type 'gen' to generate)" "gen"
if [[ "$AUTH_SECRET" == "gen" ]]; then
  AUTH_SECRET="$(openssl rand -base64 48)"
  log "Generated AUTH secret and stored in /opt/riven/.env"
fi

prompt_value POSTGRES_PASSWORD "Enter a strong Postgres password for Riven DB (or type 'gen' to generate)" "gen"
if [[ "$POSTGRES_PASSWORD" == "gen" ]]; then
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  log "Generated Postgres password and stored in /opt/riven/.env"
fi


prompt_value ZILEAN_DB_PASSWORD "Enter a strong Postgres password for Zilean DB (or type 'gen' to generate)" "gen"
if [[ "$ZILEAN_DB_PASSWORD" == "gen" ]]; then
  ZILEAN_DB_PASSWORD="$(openssl rand -hex 16)"
  log "Generated Zilean DB password and stored in /opt/zilean/.env"
fi

prompt_value PLEX_URL "Enter Plex URL (from Riven container perspective). Usually http://<server-ip>:32400" "http://${SERVER_IP}:32400"
prompt_value ZILEAN_URL "Enter Zilean URL (from Riven container perspective). Use LAN IP:8181" "http://${SERVER_IP}:8181"
ZILEAN_URL="${ZILEAN_URL%/}"

log "Installing base packages"
apt-get update && apt -y upgrade

# Base utilities (Debian minimal can be extremely slim)
apt-get install -y ca-certificates curl wget gnupg lsb-release git jq uidmap openssl   fuse3 rclone iproute2

install_docker_ce() {
  log "Installing Docker Engine + Compose plugin (Docker official repo)"

  # If Docker + Compose already work, do nothing
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and docker compose already available; skipping install"
    return 0
  fi

  # Remove distro-provided Docker bits if present (avoids conflicts)
  apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  local codename
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")"

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  # Sanity checks (fail early if something is wrong)
  docker --version
  docker compose version
}

install_docker_ce

log "Installing Plex Media Server repo + package"
# Key and repo
curl -fsSL https://downloads.plex.tv/plex-keys/PlexSign.key | gpg --dearmor -o /usr/share/keyrings/plex.gpg
echo "deb [signed-by=/usr/share/keyrings/plex.gpg] https://downloads.plex.tv/repo/deb public main" \
  > /etc/apt/sources.list.d/plexmediaserver.list
apt-get update
apt-get install -y plexmediaserver
systemctl enable --now plexmediaserver

log "Preparing directories"
mkdir -p /opt/zurg /opt/riven /opt/riven/vfs /opt/riven/data /opt/zilean

# Ensure /opt/riven/vfs is a shared mount point (required for rshared bind mounts)
# This mirrors Riven deployment best practice for mount propagation.
cat > /etc/systemd/system/riven-vfs-prepare.service <<'EOF'
[Unit]
Description=Prepare /opt/riven/vfs as a shared mount (rshared)
DefaultDependencies=no
Before=docker.service
Wants=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/mount --bind /opt/riven/vfs /opt/riven/vfs
ExecStart=/bin/mount --make-rshared /opt/riven/vfs

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now riven-vfs-prepare.service
mkdir -p /mnt/rd /mnt/media/movies /mnt/media/tv
# Plex user may not exist yet in some cases; ignore chown failure
# Keep service configs owned by root; Docker runs as root and can read 600/700 files.
chown -R root:root /opt/zurg /opt/riven /opt/zilean || true
chown -R plex:plex /mnt/media || true

chmod 700 /opt/zurg /opt/riven || true
chmod 755 /opt/zilean || true
chmod -R 775 /mnt/media || true

log "Configuring Zurg"
cat > /opt/zurg/config.yml <<EOF
zurg: v1
token: ${RD_TOKEN}
check_for_changes_every_secs: 10
enable_repair: true
auto_delete_rar_torrents: true

directories:
  tv:
    group_order: 20
    group: media
    filters:
      - has_episodes: true
  movies:
    group_order: 30
    group: media
    only_show_the_biggest_file: true
    filters:
      - regex: /.*/
EOF
chmod 600 /opt/zurg/config.yml || true


log "Starting Zurg container"
docker rm -f zurg >/dev/null 2>&1 || true
docker run -d \
  --name zurg \
  --restart unless-stopped \
  -p ${BIND_ADDR}:9999:9999 \
  -v /opt/zurg/config.yml:/app/config.yml:ro \
  -v /opt/zurg/data:/app/data \
  ghcr.io/debridmediamanager/zurg-testing:latest

log "Ensuring FUSE allow_other is enabled"
if grep -qE '^\s*#\s*user_allow_other\s*$' /etc/fuse.conf; then
  sed -i 's/^\s*#\s*user_allow_other\s*$/user_allow_other/' /etc/fuse.conf
elif ! grep -qE '^\s*user_allow_other\s*$' /etc/fuse.conf; then
  echo 'user_allow_other' >> /etc/fuse.conf
fi
grep -n 'user_allow_other' /etc/fuse.conf || true

log "Configuring rclone remote 'zurg' (non-interactive)"
# Create minimal rclone config for root if it doesn't exist
RCLONE_CONF_DIR="/root/.config/rclone"
mkdir -p "$RCLONE_CONF_DIR"
RCLONE_CONF="${RCLONE_CONF_DIR}/rclone.conf"

if ! grep -q '^\[zurg\]$' "$RCLONE_CONF" 2>/dev/null; then
cat >> "$RCLONE_CONF" <<'EOF'

[zurg]
type = webdav
url = http://127.0.0.1:9999/dav/
vendor = other
EOF
fi

log "Creating systemd unit for rclone mount"
cat > /etc/systemd/system/rclone-zurg.service <<EOF
[Unit]
Description=Rclone mount for Zurg WebDAV
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
ExecStartPre=/bin/sh -lc 'mkdir -p /mnt/rd /var/cache/rclone'
ExecStartPre=/bin/sh -lc 'mountpoint -q /mnt/rd && umount -l /mnt/rd || true'
ExecStart=/usr/bin/rclone mount zurg: /mnt/rd \
  --config /root/.config/rclone/rclone.conf \
  --allow-other --allow-non-empty \
  --dir-cache-time ${RCLONE_DIR_CACHE_TIME} \
  --vfs-cache-mode full \
  --cache-dir /var/cache/rclone \
  --vfs-cache-max-size ${RCLONE_VFS_CACHE_MAX_SIZE} \
  --vfs-cache-max-age ${RCLONE_VFS_CACHE_MAX_AGE} \
  --vfs-read-chunk-size 128M \
  --vfs-read-chunk-size-limit off \
  --buffer-size 256M \
  --poll-interval 0 \
  --umask 002
ExecStop=/bin/sh -lc 'mountpoint -q /mnt/rd && fusermount3 -uz /mnt/rd || umount -l /mnt/rd || true'
Restart=always
KillMode=process
TimeoutStopSec=30
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now rclone-zurg


# Write Zilean compose env (docker compose automatically loads .env in the project directory)
cat > /opt/zilean/.env <<EOF
ZILEAN_DB_PASSWORD=${ZILEAN_DB_PASSWORD}
BIND_ADDR=${BIND_ADDR}
EOF
chmod 600 /opt/zilean/.env || true

log "Deploying Zilean (compose)"
cat > /opt/zilean/docker-compose.yml <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    container_name: zilean-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${ZILEAN_DB_PASSWORD}
      POSTGRES_DB: zilean
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - pg-data:/var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
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
      Zilean__Database__ConnectionString: "Host=postgres;Port=5432;Database=zilean;Username=postgres;Password=${ZILEAN_DB_PASSWORD}"
    volumes:
      - zilean-data:/app/data
    ports:
      - "${BIND_ADDR}:8181:8181"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8181/healthchecks/ping >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10

volumes:
  pg-data:
  zilean-data:
EOF

( cd /opt/zilean && docker compose up -d )

log "Deploying Riven stack (compose)"
cat > /opt/riven/.env <<EOF
RIVEN_API_KEY=${RIVEN_API_KEY}
BACKEND_URL=http://riven:8080
BACKEND_API_KEY=${RIVEN_API_KEY}
AUTH_SECRET=${AUTH_SECRET}
ORIGIN=http://${SERVER_IP}:3000
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF
chmod 600 /opt/riven/.env || true


cat > /opt/riven/docker-compose.yml <<'EOF'
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
      - "${BIND_ADDR}:18080:8080"
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
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/docs >/dev/null 2>&1"]
      interval: 30s
      timeout: 10s
      retries: 10

  riven-frontend:
    image: spoked/riven-frontend:dev
    container_name: riven-frontend
    restart: unless-stopped
    ports:
      - "${BIND_ADDR}:3000:3000"
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

( cd /opt/riven && docker compose up -d )

log "Waiting briefly for services..."
sleep 3

log "Post-install automated checks"

wait_http() {
  local url="$1"
  local name="${2:-$1}"
  local max_wait="${3:-120}"
  local waited=0
  while true; do
    if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
      log "OK: ${name} is reachable at ${url}"
      return 0
    fi
    sleep 2
    waited=$((waited+2))
    if (( waited >= max_wait )); then
      log "WARN: ${name} was not reachable after ${max_wait}s: ${url}"
      return 1
    fi
  done
}

check_shared_mount() {
  local path="$1"
  if command -v findmnt >/dev/null 2>&1; then
    local prop
    prop="$(findmnt -no PROPAGATION "$path" 2>/dev/null || true)"
    if echo "$prop" | grep -qi "shared"; then
      log "OK: mount propagation for $path is '$prop'"
      return 0
    fi
    log "WARN: mount propagation for $path is '$prop' (expected shared/rshared). Riven VFS may misbehave."
    return 1
  fi
  log "WARN: findmnt not available; cannot verify mount propagation for $path"
  return 1
}

log "Checking systemd services"
systemctl is-active --quiet docker && log "OK: docker is active" || log "WARN: docker is not active"
systemctl is-active --quiet plexmediaserver && log "OK: plexmediaserver is active" || log "WARN: plexmediaserver is not active"
systemctl is-active --quiet rclone-zurg && log "OK: rclone-zurg is active" || log "WARN: rclone-zurg is not active"
systemctl is-active --quiet riven-vfs-prepare && log "OK: riven-vfs-prepare is active" || log "WARN: riven-vfs-prepare is not active"

log "Checking mount propagation prerequisites"
check_shared_mount /opt/riven/vfs || true

log "Waiting for HTTP services (local)"
wait_http "http://127.0.0.1:9999/" "Zurg UI" 120 || true
# WebDAV may 401 depending on config; PROPFIND below is the real test
wait_http "http://127.0.0.1:8181/healthchecks/ping" "Zilean" 180 || true
wait_http "http://127.0.0.1:18080/docs" "Riven backend" 240 || true
wait_http "http://127.0.0.1:3000/" "Riven frontend" 240 || true

log "Validating Zurg WebDAV endpoint"
curl -sS -X PROPFIND -H "Depth: 1" "http://127.0.0.1:9999/dav/" | head -n 10 || log "WARN: WebDAV PROPFIND failed (check Zurg config/token)"

log "Validating rclone mount is present and readable"
mount | grep -q "on /mnt/rd " && log "OK: /mnt/rd is mounted" || log "WARN: /mnt/rd does not appear mounted"
ls -lah /mnt/rd >/dev/null 2>&1 && log "OK: can list /mnt/rd" || log "WARN: cannot list /mnt/rd"

log "Validating container wiring (from inside Riven container)"
if docker ps --format '{{.Names}}' | grep -qx 'riven'; then
  docker exec riven sh -lc 'wget -qO- http://riven-db:5432 >/dev/null 2>&1 || true' >/dev/null 2>&1 || true
  docker exec riven sh -lc "wget -qO- \"${ZILEAN_URL}/healthchecks/ping\" >/dev/null 2>&1 && echo OK || echo FAIL" 2>/dev/null | head -n 1 | grep -q OK \
    && log "OK: Riven container can reach Zilean at ${ZILEAN_URL}" \
    || log "WARN: Riven container could not reach Zilean at ${ZILEAN_URL} (check BIND_ADDR/LAN IP/firewall)"
  docker exec riven sh -lc 'touch /library/_stack_test && rm -f /library/_stack_test && echo OK || echo FAIL' 2>/dev/null | head -n 1 | grep -q OK \
    && log "OK: Riven container can write to /library" \
    || log "WARN: Riven container could not write to /library (check /mnt/media permissions/mounts)"
else
  log "WARN: riven container is not running; skipping container wiring tests"
fi

log "Configure Riven settings (Zilean URL + library paths)"


# Enable Zilean and set URL to LAN IP
curl -sS -H "x-api-key: ${RIVEN_API_KEY}" -H "Content-Type: application/json" \
  -X POST -d '{"value":true}' \
  "http://127.0.0.1:18080/api/v1/settings/set/scraping/zilean/enabled" >/dev/null || true

curl -sS -H "x-api-key: ${RIVEN_API_KEY}" -H "Content-Type: application/json" \
  -X POST -d "{\"value\":\"${ZILEAN_URL}\"}" \
  "http://127.0.0.1:18080/api/v1/settings/set/scraping/zilean/url" >/dev/null || true

# Point library output to /library paths
curl -sS -H "x-api-key: ${RIVEN_API_KEY}" -H "Content-Type: application/json" \
  -X POST -d '{"value":"/library/movies"}' \
  "http://127.0.0.1:18080/api/v1/settings/set/filesystem/library_profiles/movies/library_path" >/dev/null || true

curl -sS -H "x-api-key: ${RIVEN_API_KEY}" -H "Content-Type: application/json" \
  -X POST -d '{"value":"/library/tv"}' \
  "http://127.0.0.1:18080/api/v1/settings/set/filesystem/library_profiles/tv/library_path" >/dev/null || true

log "Final notes"

ACCESS_HOST="${SERVER_IP}"
if [[ "${BIND_ADDR}" == "127.0.0.1" || "${BIND_ADDR}" == "localhost" ]]; then
  ACCESS_HOST="127.0.0.1 (local only)"
fi

cat <<EON

Riven Frontend:  http://${ACCESS_HOST}:3000
Riven Backend:   http://${ACCESS_HOST}:18080/docs
Zurg:            http://${ACCESS_HOST}:9999
Zilean:          http://${ACCESS_HOST}:8181/healthchecks/ping
Mount:           /mnt/rd  (rclone)
Plex libraries:  /mnt/media/movies and /mnt/media/tv

If BIND_ADDR is 127.0.0.1, services are only reachable locally.
For remote access, either set BIND_ADDR=0.0.0.0 (and firewall it) or use SSH port-forwarding.

Next manual steps:
1) In Riven UI -> Downloaders -> Real-Debrid: enable + paste token.
2) In Riven UI -> Updaters -> Plex: enable + set URL=${PLEX_URL} and paste Plex token.
3) Add Plex libraries pointing to /mnt/media/movies and /mnt/media/tv.
4) Add a movie in Riven and verify it appears under /mnt/media/* and plays in Plex.

EON
