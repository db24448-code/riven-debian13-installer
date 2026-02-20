#!/usr/bin/env bash
set -euo pipefail

# Debian 13 LAN-only installer for Plex + Zilean + Riven (Real-Debrid)
#
# Modes:
#   install (default): installs prereqs + writes configs + prompts for claim/RD + starts stacks
#   --reconfigure     : re-prompt key inputs + ranking preset; optionally re-claim Plex; optionally regen secrets
#   --update          : pull latest images + restart stacks (safe order) + optional tests
#   --test-only       : run tests only (requires prior install/config)
#
# Features:
# - Docker Engine + Compose plugin install (official repo)
# - systemd rshared mount propagation for /opt/media/riven/mount
# - external docker network: media-net
# - auto-generated secrets: Riven API key, frontend auth secret, Postgres passwords
# - prompt: Real-Debrid key, Plex claim token
# - order: Plex -> (claim) -> extract PlexOnlineToken -> clear claim -> Zilean -> Riven
# - ranking preset selector (TRaSH-inspired)
# - reset script: /usr/local/sbin/media-reset.sh
# - tests: systemd status, container status, mount propagation, health endpoints, DNS, /mount visibility, log scan
#
# IMPORTANT FIX in this revision:
# - systemd ExecStartPre is NOT shell-parsed; we must use /bin/sh -c for redirection/|| logic
#
# Additional improvement:
# - Zilean: persist /tmp (bind mount) as /opt/media/zilean/tmp -> /tmp

MEDIA_ROOT="/opt/media"

# ----------------------------
# helpers
# ----------------------------
log() { printf "\n[%s] %s\n" "$(date +'%H:%M:%S')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root (or with sudo)."
  fi
}

env_set() {
  # env_set <file> <KEY> <VALUE>
  local file="$1" key="$2" val="$3"
  touch "$file"
  if grep -qE "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${val}#g" "$file"
  else
    echo "${key}=${val}" >>"$file"
  fi
}

env_get() {
  # env_get <file> <KEY>
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -F= -v k="$key" '$1==k {sub(/^[^=]+=/,""); print; exit}' "$file"
}

gen_hex32() { openssl rand -hex 16; }                    # 32 hex chars
gen_b64()   { openssl rand -base64 48; }                 # auth secret
gen_pw24()  { openssl rand -base64 48 | tr -d '/+=\n' | head -c 24; }  # URL-ish safe

detect_host_ip() {
  local ip=""
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  if [[ -z "$ip" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${ip:-192.168.1.250}"
}

read_nonempty() {
  # read_nonempty "Prompt" "default"
  local prompt="$1" default="${2:-}"
  local val=""
  while [[ -z "$val" ]]; do
    if [[ -n "$default" ]]; then
      read -r -p "${prompt} [${default}]: " val
      val="${val:-$default}"
    else
      read -r -p "${prompt}: " val
    fi
  done
  echo "$val"
}

read_yesno() {
  # read_yesno "Question" "y|n(default)"
  local q="$1" def="${2:-y}"
  local ans=""
  local prompt="y/N"
  [[ "$def" == "y" ]] && prompt="Y/n"
  while true; do
    read -r -p "${q} [${prompt}]: " ans
    ans="${ans:-$def}"
    case "$ans" in
      y|Y) echo "y"; return 0 ;;
      n|N) echo "n"; return 0 ;;
      *) echo "Please enter y or n." ;;
    esac
  done
}

get_plex_token_from_prefs() {
  local prefs="$1"
  [[ -f "$prefs" ]] || return 1
  local token
  token="$(grep -oP 'PlexOnlineToken="\K[^"]+' "$prefs" 2>/dev/null | head -n 1 || true)"
  [[ -n "$token" ]] || return 1
  echo "$token"
}

apply_ranking_preset() {
  local riven_env="$1"

  echo ""
  echo "Select a ranking/quality preset:"
  echo "  1) Max Quality: 4K Remux > 1080p Remux > 4K WEB-DL > 1080p WEB-DL (prefers best audio)"
  echo "  2) Balanced:    4K WEB-DL/Bluray > 1080p Bluray/WEB-DL"
  echo "  3) 1080p HQ:    1080p Remux/Bluray > 1080p WEB-DL (good audio)"
  echo "  4) Saver:       1080p WEB-DL > 720p (no 4K, discourages remux)"
  read -r -p "Enter 1-4 [1]: " choice
  choice="${choice:-1}"

  # Baselines
  local R2160=false R1080=true R720=true R480=false
  local REMUX_USE=true REMUX_RANK=0
  local BLURAY_USE=true BLURAY_RANK=0
  local WEBDL_USE=true WEBDL_RANK=0
  local WEB_USE=true WEB_RANK=0

  local DV_USE=true DV_RANK=0
  local HDR10P_USE=true HDR10P_RANK=0
  local HDR_USE=true HDR_RANK=0
  local SDR_USE=true SDR_RANK=0

  local TRUEHD_USE=true TRUEHD_RANK=0
  local DTSLOSS_USE=true DTSLOSS_RANK=0
  local ATMOS_USE=true ATMOS_RANK=0
  local EAC3_USE=true EAC3_RANK=0
  local AAC_USE=true AAC_RANK=0

  case "$choice" in
    1)
      R2160=true; R1080=true; R720=true
      REMUX_RANK=10000; BLURAY_RANK=3000; WEBDL_RANK=2000; WEB_RANK=1500
      DV_RANK=2500; HDR10P_RANK=1800; HDR_RANK=1500; SDR_RANK=-500
      TRUEHD_RANK=2500; DTSLOSS_RANK=2200; ATMOS_RANK=1800; EAC3_RANK=500; AAC_RANK=0
      ;;
    2)
      R2160=true; R1080=true; R720=true
      REMUX_RANK=2500; BLURAY_RANK=2500; WEBDL_RANK=2400; WEB_RANK=1800
      DV_RANK=1200; HDR10P_RANK=900; HDR_RANK=700; SDR_RANK=0
      TRUEHD_RANK=1200; DTSLOSS_RANK=1100; ATMOS_RANK=900; EAC3_RANK=500; AAC_RANK=0
      ;;
    3)
      R2160=false; R1080=true; R720=true
      REMUX_RANK=4000; BLURAY_RANK=2500; WEBDL_RANK=2000; WEB_RANK=1500
      DV_RANK=600; HDR10P_RANK=0; HDR_RANK=500; SDR_RANK=0
      TRUEHD_RANK=1200; DTSLOSS_RANK=1000; ATMOS_RANK=800; EAC3_RANK=500; AAC_RANK=0
      ;;
    4)
      R2160=false; R1080=true; R720=true
      REMUX_RANK=-2000; BLURAY_RANK=500; WEBDL_RANK=2000; WEB_RANK=1800
      DV_RANK=200; HDR10P_RANK=0; HDR_RANK=200; SDR_RANK=0
      TRUEHD_RANK=200; DTSLOSS_RANK=200; ATMOS_RANK=150; EAC3_RANK=300; AAC_RANK=0
      ;;
    *)
      echo "Invalid choice, using 1"
      R2160=true; R1080=true; R720=true
      REMUX_RANK=10000; BLURAY_RANK=3000; WEBDL_RANK=2000; WEB_RANK=1500
      DV_RANK=2500; HDR10P_RANK=1800; HDR_RANK=1500; SDR_RANK=-500
      TRUEHD_RANK=2500; DTSLOSS_RANK=2200; ATMOS_RANK=1800; EAC3_RANK=500; AAC_RANK=0
      ;;
  esac

  env_set "$riven_env" "RIVEN_RANKING_RESOLUTIONS_2160P" "$R2160"
  env_set "$riven_env" "RIVEN_RANKING_RESOLUTIONS_1080P" "$R1080"
  env_set "$riven_env" "RIVEN_RANKING_RESOLUTIONS_720P"  "$R720"
  env_set "$riven_env" "RIVEN_RANKING_RESOLUTIONS_480P"  "$R480"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_REMUX_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_REMUX_USE_CUSTOM_RANK" "$REMUX_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_REMUX_RANK" "$REMUX_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_BLURAY_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_BLURAY_USE_CUSTOM_RANK" "$BLURAY_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_BLURAY_RANK" "$BLURAY_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_WEBDL_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_WEBDL_USE_CUSTOM_RANK" "$WEBDL_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_WEBDL_RANK" "$WEBDL_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_WEB_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_WEB_USE_CUSTOM_RANK" "$WEB_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_QUALITY_WEB_RANK" "$WEB_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_DOLBY_VISION_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_DOLBY_VISION_USE_CUSTOM_RANK" "$DV_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_DOLBY_VISION_RANK" "$DV_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_HDR10PLUS_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_HDR10PLUS_USE_CUSTOM_RANK" "$HDR10P_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_HDR10PLUS_RANK" "$HDR10P_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_HDR_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_HDR_USE_CUSTOM_RANK" "$HDR_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_HDR_RANK" "$HDR_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_SDR_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_SDR_USE_CUSTOM_RANK" "$SDR_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_HDR_SDR_RANK" "$SDR_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_TRUEHD_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_TRUEHD_USE_CUSTOM_RANK" "$TRUEHD_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_TRUEHD_RANK" "$TRUEHD_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_DTS_LOSSLESS_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_DTS_LOSSLESS_USE_CUSTOM_RANK" "$DTSLOSS_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_DTS_LOSSLESS_RANK" "$DTSLOSS_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_ATMOS_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_ATMOS_USE_CUSTOM_RANK" "$ATMOS_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_ATMOS_RANK" "$ATMOS_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_EAC3_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_EAC3_USE_CUSTOM_RANK" "$EAC3_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_EAC3_RANK" "$EAC3_RANK"

  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_AAC_FETCH" "true"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_AAC_USE_CUSTOM_RANK" "$AAC_USE"
  env_set "$riven_env" "RIVEN_RANKING_CUSTOM_RANKS_AUDIO_AAC_RANK" "$AAC_RANK"

  log "Ranking preset applied (choice ${choice})."
}

install_reset_script() {
  log "Installing /usr/local/sbin/media-reset.sh ..."
  cat >/usr/local/sbin/media-reset.sh <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "[1/7] Stop stacks..."
systemctl stop riven-stack.service 2>/dev/null || true
systemctl stop zilean-stack.service 2>/dev/null || true
systemctl stop plex-stack.service 2>/dev/null || true

echo "[2/7] Stop leftover containers (best-effort)..."
docker stop riven riven-frontend riven-db zilean zilean-db plex 2>/dev/null || true

echo "[3/7] Unmount stale FUSE mount (best-effort)..."
fusermount -uz /opt/media/riven/mount 2>/dev/null || true
umount -l /opt/media/riven/mount 2>/dev/null || true

echo "[4/7] Re-apply bind + rshared..."
mount --bind /opt/media/riven/mount /opt/media/riven/mount 2>/dev/null || true
mount --make-rshared /opt/media/riven/mount 2>/dev/null || true

echo "[5/7] Start Plex then Zilean then Riven..."
systemctl start plex-stack.service
systemctl start zilean-stack.service
systemctl start riven-stack.service

echo "[6/7] Status..."
systemctl --no-pager --full status plex-stack.service zilean-stack.service riven-stack.service || true

echo "[7/7] Mount propagation:"
findmnt -o TARGET,PROPAGATION /opt/media/riven/mount || true
SCRIPT
  chmod +x /usr/local/sbin/media-reset.sh
}

run_tests() {
  local host_ip="$1"
  local ok=1

  log "TEST 1/7: systemd units"
  systemctl --no-pager --full status riven-mount.service plex-stack.service zilean-stack.service riven-stack.service >/dev/null 2>&1 \
    && echo "  OK: systemd services present" \
    || { echo "  WARN: one or more systemd services not healthy"; ok=0; }

  log "TEST 2/7: Docker containers status"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | sed 's/^/  /'
  for n in plex zilean zilean-db riven riven-db riven-frontend; do
    if ! docker ps --format "{{.Names}}" | grep -qx "$n"; then
      echo "  FAIL: container not running: $n"
      ok=0
    fi
  done

  log "TEST 3/7: Mount propagation"
  local prop
  prop="$(findmnt -o PROPAGATION -n /opt/media/riven/mount 2>/dev/null || true)"
  if [[ "$prop" == "shared" ]]; then
    echo "  OK: /opt/media/riven/mount propagation is shared"
  else
    echo "  FAIL: /opt/media/riven/mount propagation is not shared (got: ${prop:-unknown})"
    ok=0
  fi

  log "TEST 4/7: Health endpoints"
  if curl -fsS "http://localhost:8181/healthchecks/ping" >/dev/null 2>&1; then
    echo "  OK: Zilean health ping"
  else
    echo "  FAIL: Zilean not healthy on http://localhost:8181/healthchecks/ping"
    ok=0
  fi

  if curl -fsSI "http://localhost:8080/docs" >/dev/null 2>&1; then
    echo "  OK: Riven backend responds at /docs"
  else
    echo "  FAIL: Riven backend not responding at http://localhost:8080/docs"
    ok=0
  fi

  if curl -fsSI "http://localhost:32400/web" >/dev/null 2>&1; then
    echo "  OK: Plex web reachable"
  else
    echo "  WARN: Plex web not reachable at http://localhost:32400/web (may still be starting)"
    ok=0
  fi

  log "TEST 5/7: In-network DNS resolution from Riven and Plex"
  if docker exec -i riven sh -lc 'getent hosts zilean plex riven-db >/dev/null 2>&1'; then
    echo "  OK: riven can resolve zilean/plex/riven-db"
  else
    echo "  FAIL: riven cannot resolve one or more service names on media-net"
    ok=0
  fi
  if docker exec -i plex sh -lc 'getent hosts riven zilean >/dev/null 2>&1'; then
    echo "  OK: plex can resolve riven/zilean"
  else
    echo "  FAIL: plex cannot resolve riven and/or zilean"
    ok=0
  fi

  log "TEST 6/7: VFS visibility inside Plex container"
  if docker exec -i plex sh -lc 'ls -la /mount >/dev/null 2>&1'; then
    echo "  OK: Plex can list /mount"
  else
    echo "  FAIL: Plex cannot access /mount (mount propagation / rshared/rslave issue likely)"
    ok=0
  fi

  log "TEST 7/7: Quick log scan for common errors (last 200 lines each)"
  local patterns='password authentication failed|Transport endpoint is not connected|Cannot open database|permission denied|Traceback|Unhandled|FATAL|panic'
  for c in riven riven-frontend riven-db zilean zilean-db plex; do
    echo "  --- $c ---"
    if docker logs --tail 200 "$c" 2>/dev/null | grep -Ei "$patterns" >/dev/null 2>&1; then
      echo "  WARN: found suspicious log lines in $c:"
      docker logs --tail 200 "$c" 2>/dev/null | grep -Ein "$patterns" | sed 's/^/    /' | head -n 30
      ok=0
    else
      echo "  OK: no obvious errors detected (tail 200)"
    fi
  done

  echo ""
  if [[ "$ok" -eq 1 ]]; then
    echo "✅ TEST SUMMARY: Looks good."
    echo "Open:"
    echo "  Plex:     http://${host_ip}:32400/web"
    echo "  Riven UI: http://${host_ip}:3000"
    echo "  Zilean:   http://${host_ip}:8181"
    return 0
  else
    echo "⚠️ TEST SUMMARY: Issues detected."
    echo "Top recovery command:"
    echo "  sudo /usr/local/sbin/media-reset.sh"
    echo "If DB password mismatch is suspected, you'll need to wipe the DB dirs (dangerous) or alter password inside Postgres."
    return 1
  fi
}

do_update() {
  local host_ip="$1"

  log "UPDATE: stopping stacks (Riven -> Zilean -> Plex)..."
  systemctl stop riven-stack.service 2>/dev/null || true
  systemctl stop zilean-stack.service 2>/dev/null || true
  systemctl stop plex-stack.service 2>/dev/null || true

  log "UPDATE: pulling latest images (Plex, Zilean, Riven)..."
  ( cd "${MEDIA_ROOT}/plex/compose"   && docker compose pull )   || true
  ( cd "${MEDIA_ROOT}/zilean/compose" && docker compose pull )   || true
  ( cd "${MEDIA_ROOT}/riven/compose"  && docker compose pull )   || true

  log "UPDATE: starting stacks (Plex -> Zilean -> Riven)..."
  systemctl start plex-stack.service
  systemctl start zilean-stack.service
  systemctl start riven-stack.service

  echo ""
  echo "Update complete."
  echo "  Plex:     http://${host_ip}:32400/web"
  echo "  Riven UI: http://${host_ip}:3000"
  echo "  Zilean:   http://${host_ip}:8181"
  echo ""

  if [[ "$(read_yesno "Run tests now?" "y")" == "y" ]]; then
    run_tests "$host_ip"
  fi
}

# ----------------------------
# args
# ----------------------------
MODE="install"
case "${1:-}" in
  --reconfigure) MODE="reconfigure" ;;
  --test-only)   MODE="test-only" ;;
  --update)      MODE="update" ;;
  "" )           MODE="install" ;;
  * )
    echo "Usage:"
    echo "  sudo bash $0               # install"
    echo "  sudo bash $0 --reconfigure  # reconfigure (RD key, ranking, optional re-claim, optional regen secrets)"
    echo "  sudo bash $0 --update       # pull latest images + restart stacks (safe order) + optional tests"
    echo "  sudo bash $0 --test-only    # run tests only"
    exit 1
    ;;
esac

need_root

HOST_UID="${SUDO_UID:-1000}"
HOST_GID="${SUDO_GID:-1000}"
DEFAULT_IP="$(detect_host_ip)"

PLEX_ENV="${MEDIA_ROOT}/plex/compose/.env"
ZILEAN_ENV="${MEDIA_ROOT}/zilean/compose/.env"
RIVEN_ENV="${MEDIA_ROOT}/riven/compose/.env"

# Fast paths that do not modify the system (require prior install)
if [[ "$MODE" == "test-only" ]]; then
  [[ -f "$RIVEN_ENV" ]] || die "Missing $RIVEN_ENV - run install first."
  HOST_IP_FINAL="$(env_get "$RIVEN_ENV" HOST_IP || echo "$DEFAULT_IP")"
  run_tests "$HOST_IP_FINAL"
  exit $?
fi

if [[ "$MODE" == "update" ]]; then
  [[ -f "$RIVEN_ENV" ]] || die "Missing $RIVEN_ENV - run install first."
  HOST_IP_FINAL="$(env_get "$RIVEN_ENV" HOST_IP || echo "$DEFAULT_IP")"
  do_update "$HOST_IP_FINAL"
  exit $?
fi

# ----------------------------
# shared install steps (idempotent)
# ----------------------------
log "Installing base packages..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release jq openssl
apt-get install -y fuse3 || true

log "Installing Docker Engine + Compose plugin..."
install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
if [[ ! -f /etc/apt/sources.list.d/docker.list ]]; then
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable
EOF
fi

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

log "Creating directory layout under ${MEDIA_ROOT}..."
mkdir -p \
  "${MEDIA_ROOT}/plex/compose" \
  "${MEDIA_ROOT}/plex/config" \
  "${MEDIA_ROOT}/zilean/compose" \
  "${MEDIA_ROOT}/zilean/db" \
  "${MEDIA_ROOT}/zilean/data" \
  "${MEDIA_ROOT}/zilean/tmp" \
  "${MEDIA_ROOT}/riven/compose" \
  "${MEDIA_ROOT}/riven/config" \
  "${MEDIA_ROOT}/riven/mount" \
  "${MEDIA_ROOT}/riven/data" \
  "${MEDIA_ROOT}/riven/db"

# ownership for bind-mounted configs (not postgres dirs)
chown -R "${HOST_UID}:${HOST_GID}" \
  "${MEDIA_ROOT}/plex/config" \
  "${MEDIA_ROOT}/zilean/data" \
  "${MEDIA_ROOT}/zilean/tmp" \
  "${MEDIA_ROOT}/riven/config" \
  "${MEDIA_ROOT}/riven/data" || true

log "Creating external docker network media-net (if missing)..."
docker network inspect media-net >/dev/null 2>&1 || docker network create media-net

log "Installing systemd unit for rshared mount propagation..."
cat >/etc/systemd/system/riven-mount.service <<'UNIT'
[Unit]
Description=Make Riven mountpoint rshared (required for Plex to see FUSE mount)
After=local-fs.target
Before=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mkdir -p /opt/media/riven/mount
ExecStart=/usr/bin/mount --bind /opt/media/riven/mount /opt/media/riven/mount
ExecStart=/usr/bin/mount --make-rshared /opt/media/riven/mount
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now riven-mount.service

install_reset_script

# ----------------------------
# Write compose files (idempotent)
# ----------------------------
log "Writing/refreshing compose files..."

cat >"${MEDIA_ROOT}/plex/compose/docker-compose.yml" <<'YAML'
services:
  plex:
    image: plexinc/pms-docker:latest
    container_name: plex
    restart: unless-stopped
    environment:
      TZ: ${TZ:-Europe/London}
      PLEX_CLAIM: ${PLEX_CLAIM:-}
      PLEX_UID: ${PLEX_UID:-1000}
      PLEX_GID: ${PLEX_GID:-1000}
    ports:
      - "32400:32400"
    volumes:
      - /opt/media/plex/config:/config
      - /opt/media/riven/mount:/mount:rslave
    networks: [media-net]

networks:
  media-net:
    external: true
YAML

cat >"${MEDIA_ROOT}/zilean/compose/docker-compose.yml" <<'YAML'
services:
  zilean-db:
    image: postgres:latest
    container_name: zilean-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${ZILEAN_DB_USER:-postgres}
      POSTGRES_PASSWORD: ${ZILEAN_DB_PASS:-postgres}
      POSTGRES_DB: ${ZILEAN_DB_NAME:-zilean}
    volumes:
      - /opt/media/zilean/db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${ZILEAN_DB_USER:-postgres} -d ${ZILEAN_DB_NAME:-zilean}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [media-net]

  zilean:
    image: ipromknight/zilean:latest
    container_name: zilean
    restart: unless-stopped
    tty: true
    ports:
      - "8181:8181"
    volumes:
      - /opt/media/zilean/data:/app/data
      - /opt/media/zilean/tmp:/tmp
    environment:
      TZ: ${TZ:-Europe/London}
      Zilean__Database__ConnectionString: "Host=zilean-db;Port=5432;Database=${ZILEAN_DB_NAME:-zilean};Username=${ZILEAN_DB_USER:-postgres};Password=${ZILEAN_DB_PASS:-postgres}"
      # Optional (avoid DMM 429):
      # Zilean__Dmm__EnableScraping: "false"
    healthcheck:
      test: ["CMD-SHELL", "curl --connect-timeout 10 --silent --show-error --fail http://localhost:8181/healthchecks/ping >/dev/null"]
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

cat >"${MEDIA_ROOT}/riven/compose/docker-compose.yml" <<'YAML'
services:
  riven-db:
    image: postgres:latest
    container_name: riven-db
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${RIVEN_DB_USER}
      POSTGRES_PASSWORD: ${RIVEN_DB_PASS}
      POSTGRES_DB: ${RIVEN_DB_NAME}
    volumes:
      - /opt/media/riven/db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${RIVEN_DB_USER} -d ${RIVEN_DB_NAME}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [media-net]

  riven:
    image: spoked/riven:dev
    container_name: riven
    restart: unless-stopped
    environment:
      TZ: ${TZ:-Europe/London}

      # Keep both keys for compatibility across dev changes
      API_KEY: ${API_KEY}
      RIVEN_API_KEY: ${API_KEY}

      RIVEN_FORCE_ENV: "true"
      RIVEN_DATABASE_HOST: postgresql+psycopg2://${RIVEN_DB_USER}:${RIVEN_DB_PASS}@riven-db:5432/${RIVEN_DB_NAME}

      RIVEN_PLEX_ENABLED: "true"
      RIVEN_PLEX_URL: http://plex:32400
      RIVEN_PLEX_TOKEN: ${PLEX_TOKEN}

      # Set both keys for compatibility (dev builds sometimes rename)
      RIVEN_SCRAPING_ZILEAN_ENABLED: "true"
      RIVEN_SCRAPING_ZILEAN_URL: http://zilean:8181
      RIVEN_SCRAPERS_ZILEAN_URL: http://zilean:8181

      RIVEN_DOWNLOADERS_REAL_DEBRID_ENABLED: "true"
      RIVEN_DOWNLOADERS_REAL_DEBRID_API_KEY: ${REALDEBRID_API_KEY}

      RIVEN_FILESYSTEM_MOUNT_PATH: ${RIVEN_FILESYSTEM_MOUNT_PATH}
      RIVEN_FILESYSTEM_CACHE_DIR: ${RIVEN_FILESYSTEM_CACHE_DIR}
      RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB: ${RIVEN_FILESYSTEM_CACHE_MAX_SIZE_MB}
      RIVEN_FILESYSTEM_CACHE_EVICTION: ${RIVEN_FILESYSTEM_CACHE_EVICTION:-LRU}
      RIVEN_FILESYSTEM_CACHE_METRICS: ${RIVEN_FILESYSTEM_CACHE_METRICS:-true}

      RIVEN_UPDATERS_LIBRARY_PATH: ${RIVEN_UPDATERS_LIBRARY_PATH}

      # Optional compatibility vars (harmless)
      PUID: ${HOST_UID}
      PGID: ${HOST_GID}
    ports:
      - "8080:8080"
    devices:
      - /dev/fuse:/dev/fuse
    cap_add: [SYS_ADMIN]
    security_opt: [apparmor:unconfined]
    shm_size: 12gb
    volumes:
      - /opt/media/riven/config:/config
      - /opt/media/riven/mount:/mount:rshared
      - /opt/media/riven/data:/riven/data
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -o /dev/null http://localhost:8080/docs || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 30s
    depends_on:
      riven-db:
        condition: service_healthy
    networks: [media-net]

  riven-frontend:
    image: spoked/riven-frontend:dev
    container_name: riven-frontend
    restart: unless-stopped
    environment:
      TZ: ${TZ:-Europe/London}
      BACKEND_URL: http://riven:8080
      BACKEND_API_KEY: ${API_KEY}
      AUTH_SECRET: ${AUTH_SECRET}
      ORIGIN: http://${HOST_IP}:3000
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

# ----------------------------
# systemd stack units
# ----------------------------
log "Installing systemd stack units..."

# NOTE: ExecStartPre must be shell-wrapped because systemd does not interpret redirection/||.
NET_PRE="/bin/sh -c '/usr/bin/docker network inspect media-net >/dev/null 2>&1 || /usr/bin/docker network create media-net'"

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
WorkingDirectory=/opt/media/plex/compose
ExecStartPre=${NET_PRE}
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
WorkingDirectory=/opt/media/zilean/compose
ExecStartPre=${NET_PRE}
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
WorkingDirectory=/opt/media/riven/compose
ExecStartPre=${NET_PRE}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable plex-stack.service zilean-stack.service riven-stack.service

# ----------------------------
# Configure / reconfigure
# ----------------------------
if [[ "$MODE" == "install" ]]; then
  log "First-time configuration (secrets + prompts)..."

  HOST_IP="$(read_nonempty "Host IP for ORIGIN (LAN IP of this server)" "$DEFAULT_IP")"
  RD_KEY="$(read_nonempty "Real-Debrid API key/token" "")"
  PLEX_CLAIM_TOKEN="$(read_nonempty "Plex claim token (from plex.tv/claim, expires quickly)" "")"

  API_KEY="$(gen_hex32)"
  AUTH_SECRET="$(gen_b64)"
  RIVEN_DB_PASS="$(gen_pw_
