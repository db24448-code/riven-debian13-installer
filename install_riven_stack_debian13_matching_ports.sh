#!/usr/bin/env bash
set -euo pipefail

echo "=== Riven + Zilean Media Stack Installer (Debian 13) - Matching Ports Edition ==="

# ---- Variables ----
RIVEN_DIR="/opt/riven"
ZILEAN_DIR="/opt/zilean"
NETWORK_NAME="zilean-net"

# ---- Install Docker if not present ----
if ! command -v docker >/dev/null 2>&1; then
  echo "[INFO] Installing Docker..."
  apt update
  apt install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo     "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian     $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |     tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable docker
  systemctl start docker
fi

# ---- Create directories ----
mkdir -p "$RIVEN_DIR" "$ZILEAN_DIR"

# ---- Riven Stack (matching ports) ----
cat > "$RIVEN_DIR/docker-compose.yml" <<EOF
services:
  riven-db:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: riven
      POSTGRES_PASSWORD: riven
      POSTGRES_DB: riven
    volumes:
      - riven-db-data:/var/lib/postgresql/data

  riven:
    image: ghcr.io/rivenmedia/riven:latest
    depends_on:
      - riven-db
    environment:
      DATABASE_URL: postgresql://riven:riven@riven-db:5432/riven
    ports:
      - "8080:8080"

  riven-frontend:
    image: ghcr.io/rivenmedia/riven-frontend:latest
    depends_on:
      - riven
    ports:
      - "3000:3000"

  zurg:
    image: ghcr.io/debridmediamanager/zurg-testing:latest
    ports:
      - "9999:9999"

volumes:
  riven-db-data:
EOF

# ---- Zilean Stack (matching ports + clean network) ----
cat > "$ZILEAN_DIR/docker-compose.yml" <<EOF
services:
  postgres:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: zilean
      POSTGRES_PASSWORD: zilean
      POSTGRES_DB: zilean
    volumes:
      - zilean-db-data:/var/lib/postgresql/data
    networks:
      - $NETWORK_NAME

  zilean:
    image: ghcr.io/debridmediamanager/zilean:latest
    depends_on:
      - postgres
    environment:
      Zilean__Database__ConnectionString: Host=postgres;Port=5432;Database=zilean;Username=zilean;Password=zilean
    ports:
      - "8181:8181"
    networks:
      - $NETWORK_NAME

volumes:
  zilean-db-data:

networks:
  $NETWORK_NAME:
    name: $NETWORK_NAME
EOF

# ---- Deploy ----
echo "[INFO] Deploying Riven stack..."
cd "$RIVEN_DIR"
docker compose up -d

echo "[INFO] Deploying Zilean stack..."
cd "$ZILEAN_DIR"
docker compose up -d

echo "=== Installation Complete ==="
echo "Riven API:      http://<server-ip>:8080"
echo "Riven Frontend: http://<server-ip>:3000"
echo "Zilean API:     http://<server-ip>:8181"
echo "Zurg:           http://<server-ip>:9999"
