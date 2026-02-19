#!/usr/bin/env bash
set -Eeuo pipefail

# Debian 13 (trixie) "Riven stack" installer - LAN-accessible (interactive v8)
# Installs: Docker CE + compose, Plex, Zurg, rclone mount (optional auto-config), Zilean+Postgres, Riven backend+frontend+Postgres
#
# Run as root:
#   bash install_riven_stack_debian13_full_REVISED_v8.sh
#
# This version is INTERACTIVE by default: it prompts for LAN IP/URLs and key material,
# but offers sane defaults (auto-detected LAN IP + generated secrets).

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
  # prompt "Question" "default" -> echoes answer
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

prompt_yn() {
  # prompt_yn "Question" "Y" -> returns 0/1
  local q="$1" def="${2:-Y}" ans
  read -r -p "$q [${def}/$( [[ "$def" == "Y" ]] && echo N || echo Y )]: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

retry() {
  local attempts="$1"; shift
  local sleep_s="$1"; shift
  [[ "${1:-}" == "--" ]] && shift
  local i=1
  until "$@"; do
    if (( i >= attempts )); then return 1; fi
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

  docker info >/dev/null 2>&1 || die "Docker installed but 'docker info' failed."
  docker compose version >/dev/null 2>&1 || die "'docker compose' not working after install."
}

############################
# Plex repo (new v2 key) + install
############################
install_plex() {
  log "Installing Plex Media Server (repo.plex.tv + PlexSign.v2.key)"

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
deploy_zurg() {
  log "Deploying Zurg container"
  mkdir -p /opt/zurg/{config,data}
  chmod 700 /opt/zurg/config
  chmod 755 /opt/zurg/data

  if [[ ! -f /opt/zurg/config/config.yml ]]; then
    log "Creating initial Zurg config.yml"
    local rd_token
    rd_token="$(prompt "Real-Debrid API token for Zurg (from https://real-debrid.com/apitoken). Leave blank to skip for now" "")"
    if [[ -z "$rd_token" ]]; then
      cat >/opt/zurg/config/config.yml <<EOF
zurg: v1
token: ${rd_token:-YOUR_RD_API_TOKEN} # https://real-debrid.com/apitoken

# Directory layout for Plex
directories:
  shows:
    group: media
    group_order: 10
    filters:
      - has_episodes: true

  movies:
    group: media
    group_order: 20
    filters:
      - has_episodes: false

# host: "[::]"
# port: 9999
EOF
      warn "Created /opt/zurg/config/config.yml with placeholder token. Zurg will not work until you add a real token."
    else
      cat >/opt/zurg/config/config.yml <<EOF
zurg: v1
token: ${rd_token} # https://real-debrid.com/apitoken

# Directory layout for Plex
directories:
  shows:
    group: media
    group_order: 10
    filters:
      - has_episodes: true

  movies:
    group: media
    group_order: 20
    filters:
      - has_episodes: false

# host: "[::]"
# port: 9999
EOF
      log "Wrote /opt/zurg/config/config.yml with provided token"
    fi
    chmod 600 /opt/zurg/config/config.yml
  fi

  # Zurg is deployed via the /opt/riven docker compose stack.
  # (No standalone docker run here.)
}


configure_rclone_remote_optional() {
  log "Installing rclone"
  apt-get install -y rclone

  mkdir -p /mnt/rd /var/cache/rclone
  chmod 755 /mnt/rd /var/cache/rclone

  if ! grep -qE '^\s*user_allow_other\s*$' /etc/fuse.conf 2>/dev/null; then
    echo "user_allow_other" >> /etc/fuse.conf
  fi

  mkdir -p /root/.config/rclone
  chmod 700 /root/.config/rclone

  if [[ ! -f /root/.config/rclone/rclone.conf ]]; then
    touch /root/.config/rclone/rclone.conf
    chmod 600 /root/.config/rclone/rclone.conf
  fi

  if rclone listremotes 2>/dev/null | grep -qx 'zurg:'; then
    log "rclone remote 'zurg' already exists"
    return 0
  fi

  
  # Zurg is served by the riven compose project (host port 9999). Wait briefly so the remote test doesn't fail on first run.
  log "Waiting for Zurg WebDAV to be reachable on 127.0.0.1:9999 (best-effort)"
  for _i in {1..30}; do
    if bash -lc '</dev/tcp/127.0.0.1/9999' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

warn "rclone remote 'zurg' is NOT configured yet."
  if ! prompt_yn "Do you want to configure the rclone 'zurg' remote now?" "Y"; then
    return 1
  fi

  local url vendor user pass
  url="$(prompt "Zurg WebDAV URL" "http://127.0.0.1:9999/dav")"
  vendor="$(prompt "WebDAV vendor (rclone webdav vendor)" "other")"
  user="$(prompt "WebDAV username (blank for none)" "")"
  if [[ -n "$user" ]]; then
    read -r -s -p "WebDAV password (input hidden): " pass
    echo ""
  else
    pass=""
  fi

  # Write remote block (simple INI). If password provided, use rclone obscure.
  local obscured=""
  if [[ -n "$pass" ]]; then
    obscured="$(printf "%s" "$pass" | rclone obscure -)"
  fi

  {
    echo ""
    echo "[zurg]"
    echo "type = webdav"
    echo "url = ${url}"
    echo "vendor = ${vendor}"
    if [[ -n "$user" ]]; then
      echo "user = ${user}"
      echo "pass = ${obscured}"
    fi
  } >> /root/.config/rclone/rclone.conf

  log "Testing rclone remote"
  if ! rclone lsd zurg: >/dev/null 2>&1; then
    warn "rclone could not access zurg:. The URL/path may be wrong. You can edit /root/.config/rclone/rclone.conf and try again."
    return 1
  fi
  log "rclone remote 'zurg' configured and reachable"
  return 0
}

install_rclone_mount_unit() {
  log "Installing systemd unit for rclone mount (zurg: -> /mnt/rd)"
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

  if rclone listremotes 2>/dev/null | grep -qx 'zurg:'; then
    log "Enabling + starting rclone-zurg.service"
    systemctl enable --now rclone-zurg.service || warn "rclone-zurg.service failed to start. Check: systemctl status rclone-zurg.service"
  else
    warn "Not enabling rclone-zurg.service because rclone remote 'zurg' is not configured."
    warn "After configuring, start it with: systemctl enable --now rclone-zurg.service"
  fi
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

  # NOTE:
  # Zilean historically used a hard-coded DB host name "postgres".
  # To avoid DNS failures (Name does not resolve), we name the DB SERVICE "postgres"
  # so the hostname "postgres" resolves inside the compose network.
  #
  # We also set the newer env var Zilean__Database__ConnectionString (if supported)
  # AND keep DATABASE_URL for compatibility.

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
      # Preferred (per community docs)
      Zilean__Database__ConnectionString: Host=postgres;Port=5432;Database=zilean;Username=zilean;Password=${zilean_pg_pw}
      # Compatibility
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


  # Preflight pull so failures are obvious (e.g. registry denied / rate limits)
  if ! (cd /opt/zilean && docker compose pull postgres zilean); then
    warn "Failed to pull Zilean or Postgres images."
    warn "If you previously used a GHCR image which returned 'denied', ensure /opt/zilean/docker-compose.yml uses a public image like 'ipromknight/zilean:latest'."
    die "Zilean image pull failed."
  fi
  (cd /opt/zilean && docker compose up -d)
}

############################
# Riven stack
############################
prepare_riven_vfs() {
  log "Preparing mount propagation for /opt/riven/vfs (rshared)"
  mkdir -p /opt/riven/vfs
  cat >/etc/systemd/system/riven-vfs-prepare.service <<'EOF'
[Unit]
Description=Prepare /opt/riven/vfs as a shared bind mount for rshared propagation
Before=docker.service
RequiresMountsFor=/opt/riven

[Service]
Type=oneshot
# Avoid stacking binds: only bind if not already a mountpoint
ExecStart=/bin/sh -lc 'mountpoint -q /opt/riven/vfs || mount --bind /opt/riven/vfs /opt/riven/vfs'
ExecStart=/bin/mount --make-rshared /opt/riven/vfs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now riven-vfs-prepare.service
}

deploy_riven() {
  log "Deploying Riven backend + frontend + Postgres (LAN accessible)"
  mkdir -p /opt/riven/data/logs
  chown -R 1000:1000 /opt/riven/data
  chmod -R u+rwX,g+rwX /opt/riven/data

  mkdir -p /mnt/media
  chmod 755 /mnt/media

  local lan_ip default_lan riven_api_key pg_pw auth_secret
  default_lan="$(get_lan_ip)"
  lan_ip="$(prompt "LAN IP address for URLs (used in printed links & frontend ORIGIN)" "$default_lan")"

  riven_api_key="$(prompt "Riven API key (32 hex chars) - leave blank to auto-generate" "")"
  if [[ -z "$riven_api_key" ]]; then
    riven_api_key="$(rand_hex_32)"
  fi
  if [[ ! "$riven_api_key" =~ ^[0-9a-fA-F]{32}$ ]]; then
    warn "Riven API key is not 32 hex chars; Riven may regenerate internally. Consider using a 32-hex key."
  fi

  pg_pw="$(prompt "Riven Postgres password - leave blank to auto-generate" "")"
  if [[ -z "$pg_pw" ]]; then
    pg_pw="$(rand_hex_32)"
  fi

  auth_secret="$(prompt "Frontend AUTH_SECRET - leave blank to auto-generate" "")"
  if [[ -z "$auth_secret" ]]; then
    auth_secret="$(rand_secret)"
  fi

  local backend_url origin
  backend_url="$(prompt "Backend URL used by frontend" "http://${lan_ip}:8080")"
  origin="$(prompt "Frontend ORIGIN" "http://${lan_ip}:3000")"

  cat >/opt/riven/.env <<EOF
RIVEN_API_KEY=${riven_api_key}
POSTGRES_PASSWORD=${pg_pw}
BACKEND_URL=${backend_url}
BACKEND_API_KEY=${riven_api_key}
AUTH_SECRET=${auth_secret}
ORIGIN=${origin}
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
      - "0.0.0.0:8080:8080"
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

  zurg:
    image: ghcr.io/debridmediamanager/zurg-testing:latest
    restart: unless-stopped
    ports:
      - "0.0.0.0:9999:9999"
    volumes:
      - /opt/zurg/config/config.yml:/app/config.yml:ro
      - /opt/zurg/data:/app/data

volumes:
  riven-frontend-data:
  riven-pg-data:
EOF

  (cd /opt/riven && docker compose --env-file .env up -d)
}

############################
# Checks / summary
############################
post_checks() {
  log "Post-install checks (best-effort)"

  systemctl is-active --quiet docker || die "docker service not active"

  echo
  echo "Container status:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed -n "1,20p" || true
  echo

  # rclone mount (optional)
  if systemctl is-enabled --quiet rclone-zurg.service 2>/dev/null; then
    if mount | grep -qE '\\s/mnt/rd\\s'; then
      echo "OK: /mnt/rd is mounted"
    else
      warn "rclone-zurg.service is enabled but /mnt/rd is not mounted (systemctl status rclone-zurg.service)."
    fi
  else
    warn "rclone-zurg.service not enabled (Plex library mount /mnt/rd will not exist until you configure + enable it)."
  fi

  # Zurg (host port)
  if retry 30 2 -- bash -lc '</dev/tcp/127.0.0.1/9999' >/dev/null 2>&1; then
    echo "OK: Zurg port 9999 is open"
  else
    warn "Zurg port 9999 not open yet (cd /opt/riven && docker compose logs zurg)."
  fi

  # Zurg token sanity (warn if Real-Debrid rejects token)
  if (cd /opt/riven && docker compose logs --tail=200 zurg 2>/dev/null) | grep -qi 'bad_token'; then
    warn "Zurg is running but Real-Debrid token was rejected (bad_token/401). Update /opt/zurg/config/config.yml and recreate zurg."
  fi

  # Riven backend docs
  if retry 30 2 -- curl -fsS http://127.0.0.1:8080/docs >/dev/null 2>&1; then
    echo "OK: Riven backend reachable (/:8080/docs)"
  else
    warn "Riven backend not responding yet (cd /opt/riven && docker compose logs riven)"
  fi

  # Riven frontend
  if retry 30 2 -- curl -fsS http://127.0.0.1:3000/ >/dev/null 2>&1; then
    echo "OK: Riven frontend reachable (/:3000)"
  else
    warn "Riven frontend not responding yet (cd /opt/riven && docker compose logs riven-frontend)"
  fi

  # Zilean
  if retry 30 2 -- curl -fsS http://127.0.0.1:8181/healthchecks/ping >/dev/null 2>&1; then
    echo "OK: Zilean healthy (/:8181/healthchecks/ping)"
  else
    warn "Zilean not healthy yet. Showing status + last logs:"
    (cd /opt/zilean && docker compose ps) || true
    (cd /opt/zilean && docker compose logs --tail=160 zilean) || true
  fi

  echo
  echo "Access URLs:"
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "${ip:-}" ]]; then
    echo "  Riven frontend: http://${ip}:3000"
    echo "  Riven backend:  http://${ip}:8080/docs"
    echo "  Zilean:         http://${ip}:8181"
    echo "  Zurg:           http://${ip}:9999"
    echo "  Mount for Plex: /mnt/rd"
  else
    echo "  Riven frontend: http://<server-ip>:3000"
    echo "  Riven backend:  http://<server-ip>:8080/docs"
    echo "  Zilean:         http://<server-ip>:8181"
    echo "  Zurg:           http://<server-ip>:9999"
    echo "  Mount for Plex: /mnt/rd"
  fi
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

  log "Deploying Zurg (config + compose service)"
  deploy_zurg

  log "Deploying Zilean"
  deploy_zilean

  log "Preparing Riven VFS"
  prepare_riven_vfs

  log "Deploying Riven (includes Zurg service)"
  deploy_riven

  log "Configuring rclone remote (optional) + installing mount unit"
  configure_rclone_remote_optional || true
  install_rclone_mount_unit

  post_checks
}

main "$@"