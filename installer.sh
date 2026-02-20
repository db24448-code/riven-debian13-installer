#!/usr/bin/env bash
set -euo pipefail

# installer.sh — Debian 13 LAN-only: Plex (host net) + Zilean + Riven (Real-Debrid)
#
# ALPHA 1 BASELINE (surgical changes only)
#
# Stack:
# - Riven backend: spoked/riven:dev (VFS / FUSE)
# - Riven frontend: spoked/riven-frontend:dev
# - Plex: plexinc/pms-docker:latest (network_mode: host)
# - Zilean: ipromknight/zilean:latest
# - Postgres pinned: postgres:17-alpine (Riven DB + Zilean DB)
# - External Docker network: media-net
# - Mount propagation via systemd riven-mount.service (rshared)
#
# IMPORTANT:
# - Riven persists settings (ranking/updaters/content). Env alone is not enough.
# - This script applies key settings via Riven Settings API (x-api-key) after Riven starts.
#
# Modes:
#   ./installer.sh                  -> interactive menu
#   ./installer.sh --install        -> install + configure + start + apply settings + tests
#   ./installer.sh --reconfigure    -> update key inputs + re-apply settings
#   ./installer.sh --update         -> pull images + restart stacks + optional tests
#   ./installer.sh --test-only      -> run tests only
#   ./installer.sh --reset          -> stop stacks + recover mount + restart
#   ./installer.sh --wipe-db        -> DANGER: wipe Postgres data dirs
#   ./installer.sh --wipe-db-reset  -> wipe DBs then reset
#   ./installer.sh --wipe-server    -> DANGER: remove stack + uninstall Docker + wipe Docker data

MEDIA_ROOT="/opt/media"

RIVEN_IMAGE="spoked/riven:dev"
RIVEN_FE_IMAGE="spoked/riven-frontend:dev"
PLEX_IMAGE="plexinc/pms-docker:latest"
ZILEAN_IMAGE="ipromknight/zilean:latest"
PG_IMAGE="postgres:17-alpine"

# Baked default Plex Watchlist RSS (account-level, stable unless regenerated)
DEFAULT_PLEX_WATCHLIST_RSS="https://rss.plex.tv/b086ad5b-7c38-4927-a6dc-f11a279c49b9"

log() { printf "\n[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (no sudo needed)."; }

env_set(){
  local f="$1" k="$2" v="$3"
  touch "$f"
  if grep -qE "^${k}=" "$f"; then
    sed -i "s#^${k}=.*#${k}=${v}#g" "$f"
  else
    echo "${k}=${v}" >>"$f"
  fi
}
env_get(){
  local f="$1" k="$2"
  [[ -f "$f" ]] || return 1
  awk -F= -v k="$k" '$1==k {sub(/^[^=]+=/,""); print; exit}' "$f"
}

gen_hex32(){ openssl rand -hex 16; }
gen_b64(){ openssl rand -base64 48; }
gen_pw24(){ openssl rand -base64 48 | tr -d '/+=\n' | head -c 24; }

detect_host_ip(){
  local ip=""
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -n "$ip" ]] || ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  echo "${ip:-192.168.1.250}"
}

read_nonempty(){
  local p="$1" d="${2:-}" v=""
  while [[ -z "$v" ]]; do
    if [[ -n "$d" ]]; then
      read -r -p "${p} [${d}]: " v
      v="${v:-$d}"
    else
      read -r -p "${p}: " v
    fi
  done
  echo "$v"
}

read_maybe(){
  local p="$1" d="${2:-}" v=""
  if [[ -n "$d" ]]; then
    read -r -p "${p} [${d}]: " v
    v="${v:-$d}"
  else
    read -r -p "${p}: " v
  fi
  echo "$v"
}

read_yesno(){
  local q="$1" def="${2:-y}" ans="" prompt="y/N"
  [[ "$def" == "y" ]] && prompt="Y/n"
  while true; do
    read -r -p "${q} [${prompt}]: " ans
    ans="${ans:-$def}"
    case "$ans" in
      y|Y) echo "y"; return 0;;
      n|N) echo "n"; return 0;;
      *) echo "Please enter y or n.";;
    esac
  done
}

get_plex_token_from_prefs(){
  local prefs="$1"
  [[ -f "$prefs" ]] || return 1
  local t
  t="$(grep -oP 'PlexOnlineToken="\K[^"]+' "$prefs" 2>/dev/null | head -n 1 || true)"
  [[ -n "$t" ]] || return 1
  echo "$t"
}

PLEX_DIR="${MEDIA_ROOT}/plex"
ZILEAN_DIR="${MEDIA_ROOT}/zilean"
RIVEN_DIR="${MEDIA_ROOT}/riven"

PLEX_COMPOSE="${PLEX_DIR}/compose"
ZILEAN_COMPOSE="${ZILEAN_DIR}/compose"
RIVEN_COMPOSE="${RIVEN_DIR}/compose"

PLEX_ENV="${PLEX_COMPOSE}/.env"
ZILEAN_ENV="${ZILEAN_COMPOSE}/.env"
RIVEN_ENV="${RIVEN_COMPOSE}/.env"

require_installed(){
  [[ -f "${PLEX_COMPOSE}/docker-compose.yml" ]] || die "Missing Plex compose. Run --install first."
  [[ -f "${ZILEAN_COMPOSE}/docker-compose.yml" ]] || die "Missing Zilean compose. Run --install first."
  [[ -f "${RIVEN_COMPOSE}/docker-compose.yml" ]] || die "Missing Riven compose. Run --install first."
  [[ -f "${PLEX_ENV}" ]] || die "Missing ${PLEX_ENV}. Run --install first."
  [[ -f "${ZILEAN_ENV}" ]] || die "Missing ${ZILEAN_ENV}. Run --install first."
  [[ -f "${RIVEN_ENV}" ]] || die "Missing ${RIVEN_ENV}. Run --install first."
}

detect_host_uid_gid(){
  local uid="" gid="" u=""

  u="$(logname 2>/dev/null || true)"
  if [[ -n "$u" && "$u" != "root" ]]; then
    uid="$(id -u "$u" 2>/dev/null || true)"
    gid="$(id -g "$u" 2>/dev/null || true)"
    if [[ -n "$uid" && -n "$gid" && "$uid" != "0" ]]; then
      echo "${uid}:${gid}"
      return 0
    fi
  fi

  if [[ -d /home ]]; then
    local candidate
    for candidate in /home/*; do
      [[ -d "$candidate" ]] || continue
      u="$(basename "$candidate")"
      uid="$(id -u "$u" 2>/dev/null || true)"
      gid="$(id -g "$u" 2>/dev/null || true)"
      if [[ -n "$uid" && -n "$gid" && "$uid" -ge 1000 ]]; then
        echo "${uid}:${gid}"
        return 0
      fi
    done
  fi

  echo "1000:1000"
}

# Prefer fusermount3 if available; fall back to fusermount.
fuse_umount(){
  local target="$1"
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "$target" 2>/dev/null || true
  fi
  if command -v fusermount >/dev/null 2>&1; then
    fusermount -uz "$target" 2>/dev/null || true
  fi
}

inline_reset(){
  systemctl stop riven-stack.service 2>/dev/null || true
  systemctl stop zilean-stack.service 2>/dev/null || true
  systemctl stop plex-stack.service 2>/dev/null || true

  docker stop riven riven-frontend riven-db zilean zilean-db plex 2>/dev/null || true

  fuse_umount /opt/media/riven/mount
  umount -l /opt/media/riven/mount 2>/dev/null || true

  mkdir -p /opt/media/riven/mount
  if ! findmnt -n /opt/media/riven/mount >/dev/null 2>&1; then
    mount --bind /opt/media/riven/mount /opt/media/riven/mount 2>/dev/null || true
  fi
  mount --make-rshared /opt/media/riven/mount 2>/dev/null || true

  systemctl start plex-stack.service
  systemctl start zilean-stack.service
  systemctl start riven-stack.service

  findmnt -o TARGET,PROPAGATION /opt/media/riven/mount || true
}

install_reset_script(){
  log "Installing /usr/local/sbin/media-reset.sh ..."
  cat >/usr/local/sbin/media-reset.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

fuse_umount(){
  local target="$1"
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -uz "$target" 2>/dev/null || true
  fi
  if command -v fusermount >/dev/null 2>&1; then
    fusermount -uz "$target" 2>/dev/null || true
  fi
}

systemctl stop riven-stack.service 2>/dev/null || true
systemctl stop zilean-stack.service 2>/dev/null || true
systemctl stop plex-stack.service 2>/dev/null || true

docker stop riven riven-frontend riven-db zilean zilean-db plex 2>/dev/null || true

fuse_umount /opt/media/riven/mount
umount -l /opt/media/riven/mount 2>/dev/null || true

mkdir -p /opt/media/riven/mount
if ! findmnt -n /opt/media/riven/mount >/dev/null 2>&1; then
  mount --bind /opt/media/riven/mount /opt/media/riven/mount 2>/dev/null || true
fi
mount --make-rshared /opt/media/riven/mount 2>/dev/null || true

systemctl start plex-stack.service
systemctl start zilean-stack.service
systemctl start riven-stack.service

findmnt -o TARGET,PROPAGATION /opt/media/riven/mount || true
SCRIPT
  chmod +x /usr/local/sbin/media-reset.sh
}

run_tests(){
  local host_ip="$1"
  local ok=1

  systemctl is-active --quiet riven-mount.service plex-stack.service zilean-stack.service riven-stack.service || ok=0

  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/  /'
  for n in plex zilean zilean-db riven riven-db riven-frontend; do
    docker ps --format "{{.Names}}" | grep -qx "$n" || ok=0
  done

  local prop
  prop="$(findmnt -o PROPAGATION -n /opt/media/riven/mount 2>/dev/null | head -n 1 || true)"
  [[ "$prop" == "shared" ]] || ok=0

  curl -fsS "http://localhost:8181/healthchecks/ping" >/dev/null 2>&1 || ok=0
  curl -fsSI "http://localhost:8080/docs" >/dev/null 2>&1 || ok=0
  curl -fsSI "http://localhost:32400/web" >/dev/null 2>&1 || ok=0

  docker exec -i plex sh -lc 'ls -la /mount >/dev/null 2>&1' || ok=0
  docker network inspect media-net >/dev/null 2>&1 || ok=0

  [[ "$ok" -eq 1 ]] && echo "✅ TEST SUMMARY: Looks good." || echo "⚠️ TEST SUMMARY: Issues detected."
  return $(( ok==1 ? 0 : 1 ))
}

stop_all(){
  systemctl stop riven-stack.service 2>/dev/null || true
  systemctl stop zilean-stack.service 2>/dev/null || true
  systemctl stop plex-stack.service 2>/dev/null || true
}

install_prereqs(){
  log "Installing prerequisites + Docker..."
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release jq openssl fuse3

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  local arch codename
  arch="$(dpkg --print-architecture)"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable
EOF
  fi

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
}

install_riven_mount_unit(){
  log "Installing systemd unit: riven-mount.service (host mountpoint rshared, idempotent)"
  cat >/etc/systemd/system/riven-mount.service <<'UNIT'
[Unit]
Description=Make Riven mountpoint rshared (required for Plex to see FUSE mount)
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '\
  set -e; \
  mkdir -p /opt/media/riven/mount; \
  if ! findmnt -n /opt/media/riven/mount >/dev/null 2>&1; then \
    mount --bind /opt/media/riven/mount /opt/media/riven/mount; \
  fi; \
  mount --make-rshared /opt/media/riven/mount; \
'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now riven-mount.service
}

ensure_layout(){
  log "Ensuring /opt/media layout..."
  mkdir -p "${PLEX_COMPOSE}" "${PLEX_DIR}/config" \
           "${ZILEAN_COMPOSE}" "${ZILEAN_DIR}/db" "${ZILEAN_DIR}/data" "${ZILEAN_DIR}/tmp" \
           "${RIVEN_COMPOSE}" "${RIVEN_DIR}/config" "${RIVEN_DIR}/mount" "${RIVEN_DIR}/data" "${RIVEN_DIR}/db"

  local ug uid gid
  ug="$(detect_host_uid_gid)"
  uid="${ug%%:*}"
  gid="${ug##*:}"

  chown -R "${uid}:${gid}" \
    "${PLEX_DIR}/config" \
    "${ZILEAN_DIR}/data" "${ZILEAN_DIR}/tmp" \
    "${RIVEN_DIR}/config" "${RIVEN_DIR}/data" || true
}

ensure_media_net(){ docker network inspect media-net >/dev/null 2>&1 || docker network create media-net; }

detect_postgres_uid_gid(){
  local uid gid
  uid="$(docker run --rm "${PG_IMAGE}" sh -lc 'id -u postgres' 2>/dev/null || true)"
  gid="$(docker run --rm "${PG_IMAGE}" sh -lc 'id -g postgres' 2>/dev/null || true)"
  [[ -n "$uid" && -n "$gid" ]] || die "Could not detect postgres uid/gid from ${PG_IMAGE}."
  echo "${uid}:${gid}"
}

fix_db_permissions(){
  log "Fixing DB bind-mount permissions (match postgres uid/gid from image)..."
  local pg_ug
  pg_ug="$(detect_postgres_uid_gid)"
  chown -R "${pg_ug}" "${ZILEAN_DIR}/db" "${RIVEN_DIR}/db" || true
}

# Ranking preset choice (kept for UX). Actual application is done via Settings API.
choose_ranking_preset(){
  echo ""
  echo "Select a ranking/quality preset:"
  echo "  1) Max Quality: 4K Remux > 1080p Remux > 4K WEB-DL > 1080p WEB-DL (prefers best audio)"
  echo "  2) Balanced:    4K WEB-DL/Bluray > 1080p Bluray/WEB-DL"
  echo "  3) 1080p HQ:    1080p Remux/Bluray > 1080p WEB-DL (good audio)"
  echo "  4) Saver:       1080p WEB-DL > 720p (no 4K, discourages remux)"
  local choice
  read -r -p "Enter 1-4 [1]: " choice
  echo "${choice:-1}"
}

write_compose_files(){
  log "Writing docker-compose.yml files..."

  # Plex: host networking
  cat >"${PLEX_COMPOSE}/docker-compose.yml" <<YAML
services:
  plex:
    image: ${PLEX_IMAGE}
    container_name: plex
    restart: unless-stopped
    network_mode: host
    environment:
      TZ: \${TZ:-Europe/London}
      VERSION: docker
      PLEX_CLAIM: \${PLEX_CLAIM:-}
      PUID: \${HOST_UID:-1000}
      PGID: \${HOST_GID:-1000}
    volumes:
      - ${PLEX_DIR}/config:/config
      - ${RIVEN_DIR}/mount:/mount:rslave
YAML

  # Zilean + DB
  cat >"${ZILEAN_COMPOSE}/docker-compose.yml" <<YAML
services:
  zilean-db:
    image: ${PG_IMAGE}
    container_name: zilean-db
    restart: unless-stopped
    environment:
      PGDATA: /var/lib/postgresql/data/pgdata
      POSTGRES_USER: \${ZILEAN_DB_USER:-postgres}
      POSTGRES_PASSWORD: \${ZILEAN_DB_PASS:-postgres}
      POSTGRES_DB: \${ZILEAN_DB_NAME:-zilean}
    volumes:
      - ${ZILEAN_DIR}/db:/var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${ZILEAN_DB_USER:-postgres} -d \${ZILEAN_DB_NAME:-zilean}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [media-net]

  zilean:
    image: ${ZILEAN_IMAGE}
    container_name: zilean
    restart: unless-stopped
    tty: true
    ports:
      - "8181:8181"
    volumes:
      - ${ZILEAN_DIR}/data:/app/data
      - ${ZILEAN_DIR}/tmp:/tmp
    environment:
      TZ: \${TZ:-Europe/London}
      Zilean__Database__ConnectionString: "Host=zilean-db;Port=5432;Database=\${ZILEAN_DB_NAME:-zilean};Username=\${ZILEAN_DB_USER:-postgres};Password=\${ZILEAN_DB_PASS:-postgres}"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8181/healthchecks/ping >/dev/null 2>&1 && exit 0; if command -v curl >/dev/null 2>&1; then curl --connect-timeout 10 --silent --show-error --fail http://localhost:8181/healthchecks/ping >/dev/null && exit 0; fi; exit 0"]
      interval: 30s
      timeout: 60s
      retries: 10
      start_period: 60s
    depends_on:
      zilean-db:
        condition: service_healthy
    networks: [media-net]

networks:
  media-net:
    external: true
YAML

  # Riven + DB + frontend
  cat >"${RIVEN_COMPOSE}/docker-compose.yml" <<YAML
services:
  riven-db:
    image: ${PG_IMAGE}
    container_name: riven-db
    restart: unless-stopped
    environment:
      PGDATA: /var/lib/postgresql/data/pgdata
      POSTGRES_USER: \${RIVEN_DB_USER}
      POSTGRES_PASSWORD: \${RIVEN_DB_PASS}
      POSTGRES_DB: \${RIVEN_DB_NAME}
    volumes:
      - ${RIVEN_DIR}/db:/var/lib/postgresql/data/pgdata
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${RIVEN_DB_USER} -d \${RIVEN_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [media-net]

  riven:
    image: ${RIVEN_IMAGE}
    container_name: riven
    restart: unless-stopped
    env_file:
      - .env
    environment:
      TZ: \${TZ:-Europe/London}
      RIVEN_FORCE_ENV: "true"
      RIVEN_DATABASE_HOST: postgresql+psycopg2://\${RIVEN_DB_USER}:\${RIVEN_DB_PASS}@riven-db:5432/\${RIVEN_DB_NAME}
      # Keep service wiring here; persisted settings are applied via API after startup:
      RIVEN_SCRAPING_ZILEAN_ENABLED: "true"
      RIVEN_SCRAPING_ZILEAN_URL: http://zilean:8181
      RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED: "true"
      RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY: \${REALDEBRID_API_KEY}
      RIVEN_FILESYSTEM_MOUNT_PATH: \${RIVEN_FILESYSTEM_MOUNT_PATH}
      RIVEN_FILESYSTEM_CACHE_DIR: \${RIVEN_FILESYSTEM_CACHE_DIR}
      RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB: \${RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB}
      RIVEN_FILESYSTEM_CACHE_EVICTION: \${RIVEN_FILESYSTEM_CACHE_EVICTION:-LRU}
      RIVEN_FILESYSTEM_CACHE_METRICS: \${RIVEN_FILESYSTEM_CACHE_METRICS:-true}
      RIVEN_UPDATERS_LIBRARY_PATH: \${RIVEN_UPDATERS_LIBRARY_PATH}
      PUID: \${HOST_UID}
      PGID: \${HOST_GID}
    ports:
      - "8080:8080"
    devices:
      - /dev/fuse:/dev/fuse
    cap_add: [SYS_ADMIN]
    security_opt: [apparmor:unconfined]
    shm_size: 12gb
    volumes:
      - ${RIVEN_DIR}/config:/config
      - ${RIVEN_DIR}/mount:/mount:rshared
      - ${RIVEN_DIR}/data:/riven/data
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/docs >/dev/null 2>&1 && exit 0; if command -v curl >/dev/null 2>&1; then curl -fsSI -o /dev/null http://localhost:8080/docs && exit 0; fi; exit 0"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 30s
    depends_on:
      riven-db:
        condition: service_healthy
    networks: [media-net]

  riven-frontend:
    image: ${RIVEN_FE_IMAGE}
    container_name: riven-frontend
    restart: unless-stopped
    environment:
      TZ: \${TZ:-Europe/London}
      BACKEND_URL: http://riven:8080
      BACKEND_API_KEY: \${API_KEY}
      AUTH_SECRET: \${AUTH_SECRET}
      ORIGIN: http://\${HOST_IP}:3000
      DATABASE_URL: /riven/data/riven.db
    volumes:
      - riven-frontend-data:/riven/data
    ports:
      - "3000:3000"
    depends_on:
      riven:
        condition: service_healthy
    networks: [media-net]

networks:
  media-net:
    external: true

volumes:
  riven-frontend-data:
YAML
}

write_systemd_units(){
  log "Writing systemd stack units..."
  local net_pre
  net_pre="/bin/sh -c '/usr/bin/docker network inspect media-net >/dev/null 2>&1 || /usr/bin/docker network create media-net'"

  cat >/etc/systemd/system/plex-stack.service <<UNIT
[Unit]
Description=Plex stack (Compose)
Requires=docker.service riven-mount.service
After=docker.service riven-mount.service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PLEX_COMPOSE}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT

  cat >/etc/systemd/system/zilean-stack.service <<UNIT
[Unit]
Description=Zilean stack (Compose)
Requires=docker.service
After=docker.service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${ZILEAN_COMPOSE}
ExecStartPre=${net_pre}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT

  cat >/etc/systemd/system/riven-stack.service <<UNIT
[Unit]
Description=Riven stack (Compose)
Requires=docker.service riven-mount.service plex-stack.service zilean-stack.service
After=docker.service riven-mount.service plex-stack.service zilean-stack.service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${RIVEN_COMPOSE}
ExecStartPre=${net_pre}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable plex-stack.service zilean-stack.service riven-stack.service
}

configure_install(){
  log "Creating initial .env files..."
  local host_ip rd_key plex_claim api_key auth_secret riven_db_pass zilean_db_pass
  host_ip="$(read_nonempty "Host IP for Plex/Riven UI (LAN IP of this server)" "$(detect_host_ip)")"
  rd_key="$(read_nonempty "Real-Debrid API key/token" "")"
  plex_claim="$(read_nonempty "Plex claim token (plex.tv/claim)" "")"

  api_key="$(gen_hex32)"; auth_secret="$(gen_b64)"
  riven_db_pass="$(gen_pw24)"; zilean_db_pass="$(gen_pw24)"

  local ug uid gid
  ug="$(detect_host_uid_gid)"
  uid="${ug%%:*}"; gid="${ug##*:}"

  cat >"${PLEX_ENV}" <<ENV
TZ=Europe/London
PLEX_CLAIM=${plex_claim}
HOST_UID=${uid}
HOST_GID=${gid}
ENV

  cat >"${ZILEAN_ENV}" <<ENV
TZ=Europe/London
ZILEAN_DB_USER=postgres
ZILEAN_DB_PASS=${zilean_db_pass}
ZILEAN_DB_NAME=zilean
ENV

  cat >"${RIVEN_ENV}" <<ENV
TZ=Europe/London
HOST_IP=${host_ip}
HOST_UID=${uid}
HOST_GID=${gid}

API_KEY=${api_key}
AUTH_SECRET=${auth_secret}

RIVEN_DB_USER=riven
RIVEN_DB_PASS=${riven_db_pass}
RIVEN_DB_NAME=riven

REALDEBRID_API_KEY=${rd_key}
PLEX_TOKEN=

# baked default (can be overridden later)
PLEX_WATCHLIST_RSS=${DEFAULT_PLEX_WATCHLIST_RSS}

RIVEN_FILESYSTEM_MOUNT_PATH=/mount
RIVEN_FILESYSTEM_CACHE_DIR=/dev/shm/riven-cache
RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB=10240
RIVEN_FILESYSTEM_CACHE_EVICTION=LRU
RIVEN_FILESYSTEM_CACHE_METRICS=true
RIVEN_UPDATERS_LIBRARY_PATH=/mount
ENV

  local preset
  preset="$(choose_ranking_preset)"
  env_set "${RIVEN_ENV}" "RIVEN_RANKING_PRESET_CHOICE" "${preset}"
}

start_plex_and_extract_token(){
  log "Starting Plex and extracting PlexOnlineToken..."
  systemctl start plex-stack.service

  local prefs_path token host_ip
  prefs_path="${PLEX_DIR}/config/Library/Application Support/Plex Media Server/Preferences.xml"
  token="$(env_get "${RIVEN_ENV}" PLEX_TOKEN || true)"
  host_ip="$(env_get "${RIVEN_ENV}" HOST_IP || echo "$(detect_host_ip)")"

  if [[ -z "$token" ]]; then
    local found=""
    for _ in $(seq 1 90); do
      found="$(get_plex_token_from_prefs "$prefs_path" || true)"
      [[ -n "$found" ]] && break
      sleep 2
    done
    [[ -n "$found" ]] || die "Could not read PlexOnlineToken. Open http://${host_ip}:32400/web and claim, then rerun."

    env_set "${RIVEN_ENV}" "PLEX_TOKEN" "${found}"
    env_set "${PLEX_ENV}" "PLEX_CLAIM" ""
    ( cd "${PLEX_COMPOSE}" && docker compose up -d ) >/dev/null 2>&1 || true
  else
    env_set "${PLEX_ENV}" "PLEX_CLAIM" ""
  fi
}

start_all(){
  start_plex_and_extract_token
  systemctl start zilean-stack.service
  systemctl start riven-stack.service
}

wait_riven_ready(){
  # Wait for /docs to be reachable
  for _ in $(seq 1 90); do
    if curl -fsSI http://localhost:8080/docs >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Apply key persisted settings via API (ranking lists + custom ranks + plex updater + watchlist)
apply_riven_settings_api(){
  require_installed
  local api_key host_ip plex_token rss preset
  api_key="$(env_get "${RIVEN_ENV}" API_KEY || true)"
  host_ip="$(env_get "${RIVEN_ENV}" HOST_IP || true)"
  plex_token="$(env_get "${RIVEN_ENV}" PLEX_TOKEN || true)"
  rss="$(env_get "${RIVEN_ENV}" PLEX_WATCHLIST_RSS || true)"
  preset="$(env_get "${RIVEN_ENV}" RIVEN_RANKING_PRESET_CHOICE || echo "1")"

  [[ -n "$api_key" ]] || die "Missing API_KEY in ${RIVEN_ENV}"
  [[ -n "$host_ip" ]] || host_ip="$(detect_host_ip)"
  [[ -n "$plex_token" ]] || die "Missing PLEX_TOKEN in ${RIVEN_ENV} (claim Plex first)"

  # Ensure RSS exists; use baked default if empty
  if [[ -z "${rss}" ]]; then
    rss="${DEFAULT_PLEX_WATCHLIST_RSS}"
    env_set "${RIVEN_ENV}" "PLEX_WATCHLIST_RSS" "${rss}"
  fi

  log "Waiting for Riven API to be ready..."
  wait_riven_ready || die "Riven did not become ready at http://localhost:8080/docs"

  # Backup settings snapshot (helps protect against accidental overwrites)
  mkdir -p "${RIVEN_DIR}/config"
  local ts; ts="$(date +%F-%H%M%S)"
  curl -fsS -H "x-api-key: ${api_key}" http://localhost:8080/api/v1/settings/get/all > "${RIVEN_DIR}/config/settings-backup-${ts}.json" || true

  # ---- UPDATERS (Plex library updates) ----
  log "Applying Plex updater settings via API..."
  curl -fsS -H "x-api-key: ${api_key}" -H "content-type: application/json" \
    --data-binary @- \
    http://localhost:8080/api/v1/settings/set/updaters <<JSON
{
  "updaters": {
    "library_path": "/mount",
    "plex": {
      "enabled": true,
      "url": "http://${host_ip}:32400",
      "token": "${plex_token}"
    }
  }
}
JSON

  # ---- CONTENT (Plex Watchlist RSS) ----
  log "Applying Plex Watchlist settings via API..."
  curl -fsS -H "x-api-key: ${api_key}" -H "content-type: application/json" \
    --data-binary @- \
    http://localhost:8080/api/v1/settings/set/content <<JSON
{
  "content": {
    "plex_watchlist": {
      "enabled": true,
      "update_interval": 60,
      "rss": ["${rss}"]
    }
  }
}
JSON

  # ---- RANKING (RTN lists + ranks) ----
  log "Applying ranking preset ${preset} via API..."
  local exclude_json preferred_json r2160 remux_rank bluray_rank webdl_rank web_rank dv_rank hdr10p_rank hdr_rank sdr_rank truehd_rank dtsloss_rank atmos_rank eac3_rank aac_rank

  case "${preset}" in
    1)
      r2160="true"
      remux_rank=10000; bluray_rank=3000; webdl_rank=2000; web_rank=1500
      dv_rank=2500; hdr10p_rank=1800; hdr_rank=1500; sdr_rank=-500
      truehd_rank=2500; dtsloss_rank=2200; atmos_rank=1800; eac3_rank=500; aac_rank=0
      ;;
    2)
      r2160="true"
      remux_rank=2500; bluray_rank=2500; webdl_rank=2400; web_rank=1800
      dv_rank=1200; hdr10p_rank=900; hdr_rank=700; sdr_rank=0
      truehd_rank=1200; dtsloss_rank=1100; atmos_rank=900; eac3_rank=500; aac_rank=0
      ;;
    3)
      r2160="false"
      remux_rank=4000; bluray_rank=2500; webdl_rank=2000; web_rank=1500
      dv_rank=600; hdr10p_rank=0; hdr_rank=500; sdr_rank=0
      truehd_rank=1200; dtsloss_rank=1000; atmos_rank=800; eac3_rank=500; aac_rank=0
      ;;
    4)
      r2160="false"
      remux_rank=-2000; bluray_rank=500; webdl_rank=2000; web_rank=1800
      dv_rank=200; hdr10p_rank=0; hdr_rank=200; sdr_rank=0
      truehd_rank=200; dtsloss_rank=200; atmos_rank=150; eac3_rank=300; aac_rank=0
      ;;
    *)
      r2160="true"
      remux_rank=10000; bluray_rank=3000; webdl_rank=2000; web_rank=1500
      dv_rank=2500; hdr10p_rank=1800; hdr_rank=1500; sdr_rank=-500
      truehd_rank=2500; dtsloss_rank=2200; atmos_rank=1800; eac3_rank=500; aac_rank=0
      ;;
  esac

  # Patterns (what you wanted to see in UI lists)
  exclude_json='["\\bCAM\\b","\\bTS\\b","\\bTC\\b","\\bSCR\\b","\\bDVDSCR\\b","\\bHDCAM\\b","\\bTELESYNC\\b"]'
  preferred_json='["\\bREMUX\\b","\\bBLURAY\\b","\\bTRUEHD\\b","\\bATMOS\\b","\\bDTS[- ]?HD\\b","\\bDTS:?X\\b","\\bDOLBY[ .-]?VISION\\b","\\bDV\\b","\\bHDR10\\+\\b","\\bHDR\\b"]'

  # Fetch current ranking, merge changes with jq (prevents wiping other keys)
  local cur_rank tmp_rank
  cur_rank="$(curl -fsS -H "x-api-key: ${api_key}" http://localhost:8080/api/v1/settings/get/ranking)"
  tmp_rank="$(mktemp)"
  echo "${cur_rank}" | jq \
    --argjson ex "${exclude_json}" \
    --argjson pref "${preferred_json}" \
    --arg r2160 "${r2160}" \
    --argjson remux_rank "${remux_rank}" \
    --argjson bluray_rank "${bluray_rank}" \
    --argjson webdl_rank "${webdl_rank}" \
    --argjson web_rank "${web_rank}" \
    --argjson dv_rank "${dv_rank}" \
    --argjson hdr10p_rank "${hdr10p_rank}" \
    --argjson hdr_rank "${hdr_rank}" \
    --argjson sdr_rank "${sdr_rank}" \
    --argjson truehd_rank "${truehd_rank}" \
    --argjson dtsloss_rank "${dtsloss_rank}" \
    --argjson atmos_rank "${atmos_rank}" \
    --argjson eac3_rank "${eac3_rank}" \
    --argjson aac_rank "${aac_rank}" \
    '
    .ranking.exclude = $ex
    | .ranking.preferred = $pref
    | .ranking.enabled = true
    | .ranking.resolutions.r2160p = ($r2160=="true")
    | .ranking.custom_ranks.quality.remux.fetch = true
    | .ranking.custom_ranks.quality.remux.use_custom_rank = true
    | .ranking.custom_ranks.quality.remux.rank = $remux_rank
    | .ranking.custom_ranks.quality.bluray.fetch = true
    | .ranking.custom_ranks.quality.bluray.use_custom_rank = true
    | .ranking.custom_ranks.quality.bluray.rank = $bluray_rank
    | .ranking.custom_ranks.quality.webdl.fetch = true
    | .ranking.custom_ranks.quality.webdl.use_custom_rank = true
    | .ranking.custom_ranks.quality.webdl.rank = $webdl_rank
    | .ranking.custom_ranks.quality.web.fetch = true
    | .ranking.custom_ranks.quality.web.use_custom_rank = true
    | .ranking.custom_ranks.quality.web.rank = $web_rank
    | .ranking.custom_ranks.hdr.dolby_vision.fetch = true
    | .ranking.custom_ranks.hdr.dolby_vision.use_custom_rank = true
    | .ranking.custom_ranks.hdr.dolby_vision.rank = $dv_rank
    | .ranking.custom_ranks.hdr.hdr10plus.fetch = true
    | .ranking.custom_ranks.hdr.hdr10plus.use_custom_rank = true
    | .ranking.custom_ranks.hdr.hdr10plus.rank = $hdr10p_rank
    | .ranking.custom_ranks.hdr.hdr.fetch = true
    | .ranking.custom_ranks.hdr.hdr.use_custom_rank = true
    | .ranking.custom_ranks.hdr.hdr.rank = $hdr_rank
    | .ranking.custom_ranks.hdr.sdr.fetch = true
    | .ranking.custom_ranks.hdr.sdr.use_custom_rank = true
    | .ranking.custom_ranks.hdr.sdr.rank = $sdr_rank
    | .ranking.custom_ranks.audio.truehd.fetch = true
    | .ranking.custom_ranks.audio.truehd.use_custom_rank = true
    | .ranking.custom_ranks.audio.truehd.rank = $truehd_rank
    | .ranking.custom_ranks.audio.dts_lossless.fetch = true
    | .ranking.custom_ranks.audio.dts_lossless.use_custom_rank = true
    | .ranking.custom_ranks.audio.dts_lossless.rank = $dtsloss_rank
    | .ranking.custom_ranks.audio.atmos.fetch = true
    | .ranking.custom_ranks.audio.atmos.use_custom_rank = true
    | .ranking.custom_ranks.audio.atmos.rank = $atmos_rank
    | .ranking.custom_ranks.audio.eac3.fetch = true
    | .ranking.custom_ranks.audio.eac3.use_custom_rank = true
    | .ranking.custom_ranks.audio.eac3.rank = $eac3_rank
    | .ranking.custom_ranks.audio.aac.fetch = true
    | .ranking.custom_ranks.audio.aac.use_custom_rank = true
    | .ranking.custom_ranks.audio.aac.rank = $aac_rank
    ' > "${tmp_rank}"

  # Post updated ranking object back
  curl -fsS -H "x-api-key: ${api_key}" -H "content-type: application/json" \
    --data-binary @- \
    http://localhost:8080/api/v1/settings/set/ranking <<JSON
$(cat "${tmp_rank}")
JSON
  rm -f "${tmp_rank}"

  log "Riven settings applied via API (ranking + plex updater + watchlist)."
}

do_update(){
  local host_ip="$1"
  require_installed
  stop_all
  fix_db_permissions || true

  ( cd "${PLEX_COMPOSE}" && docker compose pull ) || true
  ( cd "${ZILEAN_COMPOSE}" && docker compose pull ) || true
  ( cd "${RIVEN_COMPOSE}" && docker compose pull ) || true

  systemctl start plex-stack.service
  systemctl start zilean-stack.service
  systemctl start riven-stack.service

  # Re-apply persisted settings (safe; idempotent)
  apply_riven_settings_api || true

  [[ "$(read_yesno "Run tests now?" "y")" == "y" ]] && run_tests "$host_ip" || true
}

do_reset(){
  require_installed
  if [[ -x /usr/local/sbin/media-reset.sh ]]; then
    /usr/local/sbin/media-reset.sh
  else
    log "Reset script missing; using inline reset and reinstalling helper..."
    inline_reset
    install_reset_script
  fi
}

do_wipe_db(){
  log "DANGER: wiping DB dirs (stopping stacks first)..."
  require_installed
  stop_all
  rm -rf "${ZILEAN_DIR}/db" "${RIVEN_DIR}/db"
  mkdir -p "${ZILEAN_DIR}/db" "${RIVEN_DIR}/db"
  fix_db_permissions
}

do_reconfigure(){
  log "Reconfigure (preserve DBs/config; no wipe)."
  require_installed

  local cur_host_ip cur_rd cur_rss
  cur_host_ip="$(env_get "${RIVEN_ENV}" HOST_IP || echo "$(detect_host_ip)")"
  cur_rd="$(env_get "${RIVEN_ENV}" REALDEBRID_API_KEY || true)"
  cur_rss="$(env_get "${RIVEN_ENV}" PLEX_WATCHLIST_RSS || echo "${DEFAULT_PLEX_WATCHLIST_RSS}")"

  local host_ip rd_key
  host_ip="$(read_nonempty "Host IP (LAN IP of this server)" "${cur_host_ip}")"
  rd_key="$(read_nonempty "Real-Debrid API key/token" "${cur_rd}")"
  env_set "${RIVEN_ENV}" "HOST_IP" "${host_ip}"
  env_set "${RIVEN_ENV}" "REALDEBRID_API_KEY" "${rd_key}"

  # baked default; allow override
  local rss
  rss="$(read_maybe "Plex Watchlist RSS URL (Enter to keep)" "${cur_rss}")"
  env_set "${RIVEN_ENV}" "PLEX_WATCHLIST_RSS" "${rss}"

  if [[ "$(read_yesno "Change ranking/quality preset now?" "n")" == "y" ]]; then
    local preset; preset="$(choose_ranking_preset)"
    env_set "${RIVEN_ENV}" "RIVEN_RANKING_PRESET_CHOICE" "${preset}"
  fi

  if [[ "$(read_yesno "Rotate API_KEY + AUTH_SECRET? (breaks UI sessions)" "n")" == "y" ]]; then
    env_set "${RIVEN_ENV}" "API_KEY" "$(gen_hex32)"
    env_set "${RIVEN_ENV}" "AUTH_SECRET" "$(gen_b64)"
  fi

  if [[ "$(read_yesno "Re-claim Plex now (refresh Plex token)?" "n")" == "y" ]]; then
    local plex_claim
    plex_claim="$(read_nonempty "Plex claim token (plex.tv/claim)" "")"
    env_set "${PLEX_ENV}" "PLEX_CLAIM" "${plex_claim}"
    env_set "${RIVEN_ENV}" "PLEX_TOKEN" ""
    start_plex_and_extract_token
  fi

  log "Restarting stacks to apply changes..."
  stop_all
  systemctl start plex-stack.service
  systemctl start zilean-stack.service
  systemctl start riven-stack.service

  apply_riven_settings_api

  [[ "$(read_yesno "Run tests now?" "y")" == "y" ]] && run_tests "${host_ip}" || true
}

wipe_server(){
  need_root
  log "DANGER: This will REMOVE the entire stack AND uninstall Docker + wipe Docker data."
  log "This is intended for fresh-server testing. It will delete ALL Docker images/volumes/containers on this machine."

  echo
  echo "Type WIPE-SERVER to confirm:"
  read -r confirm
  [[ "${confirm}" == "WIPE-SERVER" ]] || die "Aborted."

  log "Stopping stack services (best-effort)..."
  systemctl stop riven-stack.service zilean-stack.service plex-stack.service 2>/dev/null || true
  systemctl stop riven-mount.service 2>/dev/null || true

  log "Removing stack containers (best-effort)..."
  if command -v docker >/dev/null 2>&1; then
    docker rm -f plex zilean zilean-db riven riven-db riven-frontend 2>/dev/null || true
  fi

  log "Unmounting mountpoint (best-effort)..."
  fuse_umount /opt/media/riven/mount
  umount -l /opt/media/riven/mount 2>/dev/null || true

  log "Removing stack data under ${MEDIA_ROOT} ..."
  rm -rf "${MEDIA_ROOT}"

  log "Removing helper script..."
  rm -f /usr/local/sbin/media-reset.sh

  log "Removing systemd units..."
  rm -f /etc/systemd/system/plex-stack.service \
        /etc/systemd/system/zilean-stack.service \
        /etc/systemd/system/riven-stack.service \
        /etc/systemd/system/riven-mount.service
  systemctl daemon-reload

  log "Removing docker network media-net (best-effort)..."
  if command -v docker >/dev/null 2>&1; then
    docker network rm media-net 2>/dev/null || true
  fi

  log "Stopping Docker + wiping Docker data..."
  systemctl stop docker 2>/dev/null || true
  systemctl stop containerd 2>/dev/null || true
  rm -rf /var/lib/docker /var/lib/containerd

  log "Uninstalling Docker packages (purge)..."
  apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
  apt-get purge -y docker-ce-rootless-extras docker-compose 2>/dev/null || true

  log "Removing Docker apt repo + key (added by installer)..."
  rm -f /etc/apt/sources.list.d/docker.list
  rm -f /etc/apt/keyrings/docker.gpg

  log "Optionally remove prereqs installed by installer..."
  if [[ "$(read_yesno "Also purge prereq packages (curl, gnupg, jq, openssl, fuse3, etc.)?" "n")" == "y" ]]; then
    apt-get purge -y jq fuse3 gnupg lsb-release curl openssl ca-certificates 2>/dev/null || true
  fi

  log "Autoremove leftover deps..."
  apt-get autoremove -y || true
  apt-get autoclean -y || true

  log "WIPE-SERVER complete."
}

main(){
  need_root
  local mode="${1:-}"

  if [[ -z "$mode" ]]; then
    echo "1) Install  2) Reconfigure  3) Update  4) Test-only  5) Reset  6) Wipe DB + Reset  7) WIPE-SERVER"
    read -r -p "Choose [1]: " c; c="${c:-1}"
    case "$c" in
      1) mode="--install";;
      2) mode="--reconfigure";;
      3) mode="--update";;
      4) mode="--test-only";;
      5) mode="--reset";;
      6) mode="--wipe-db-reset";;
      7) mode="--wipe-server";;
      *) mode="--install";;
    esac
  fi

  case "$mode" in
    --install)
      install_prereqs
      ensure_layout
      ensure_media_net
      install_riven_mount_unit
      install_reset_script

      docker pull "${PG_IMAGE}" >/dev/null
      fix_db_permissions

      write_compose_files
      write_systemd_units
      configure_install
      start_all

      # Apply persisted settings via API after Riven is up
      apply_riven_settings_api

      local host_ip
      host_ip="$(env_get "${RIVEN_ENV}" HOST_IP || echo "$(detect_host_ip)")"

      if [[ "$(read_yesno "Run post-install tests now?" "y")" == "y" ]]; then
        log "Running tests (with brief retry)..."
        for attempt in 1 2 3; do
          if run_tests "$host_ip"; then
            break
          fi
          log "Tests reported issues (attempt ${attempt}/3). Waiting 15s and retrying..."
          sleep 15
        done
      fi
      ;;

    --reconfigure)
      do_reconfigure
      ;;

    --update)
      require_installed
      local host_ip
      host_ip="$(env_get "${RIVEN_ENV}" HOST_IP || echo "$(detect_host_ip)")"
      do_update "$host_ip"
      ;;

    --test-only)
      require_installed
      local host_ip
      host_ip="$(env_get "${RIVEN_ENV}" HOST_IP || echo "$(detect_host_ip)")"
      run_tests "$host_ip"
      ;;

    --reset)
      do_reset
      ;;

    --wipe-db)
      do_wipe_db
      ;;

    --wipe-db-reset)
      do_wipe_db
      do_reset
      ;;

    --wipe-server)
      wipe_server
      ;;

    *)
      die "Unknown mode: $mode"
      ;;
  esac
}

main "${1:-}"