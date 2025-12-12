#!/bin/bash
# GreatHost n8n One-Click Installer
# - Full GreatHost branding (ASCII cow)
# - Supports: Ubuntu (apt) & AlmaLinux/CentOS/RHEL (dnf)
# - Docker (non-interactive) + Docker Compose plugin
# - Postgres (Docker)
# - n8n (Docker)
# - Nginx reverse proxy + Certbot (Let's Encrypt) auto
# - Firewall rules (ufw/firewalld) auto
# - SELinux adjustments (RHEL-like)
# - SysV patch to avoid docker installer freeze
# - Robust error handling and logging
#
# Usage:
#   sudo bash greathost-n8n-installer.sh
#
# Author: GreatHost.in (Ritik26)
# NOTE: Read comments in the file before modifying.

set -eo pipefail   # don't use -u (it can cause early exit on unset vars)

# -----------------------------
# Configuration / Constants
# -----------------------------
LOGFILE="/var/log/greathost-n8n-install.log"
INSTALL_DIR="/opt/greathost-n8n"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SYSV_BIN="/usr/lib/systemd/systemd-sysv-install"
SYSV_BACKUP="${SYSV_BIN}.greathost.bak"

# Colors
GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
RESET="\e[0m"

# Logging helper
log() {
  echo -e "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

# Safe command runner - allow non-fatal with || true when needed
run() {
  log "+ $*"
  if ! eval "$@"; then
    log "!! Command failed: $*"
    return 1
  fi
  return 0
}

# check command and exit with message
fatal() {
  echo -e "${RED}FATAL:${RESET} $*" | tee -a "$LOGFILE" >&2
  exit 1
}

# -----------------------------
# Branding banner (GreatHost cow)
# -----------------------------
clear
cat <<'EOF'

 ____________________________________________________________________
|                                                                    |
|    ===========================================                     |
|    ::..𝐓𝐡𝐢𝐬 𝐬𝐞𝐫𝐯𝐞𝐫 𝐢𝐬 𝐬𝐞𝐭 𝐛𝐲 GreatHost.in...::               |
|    ===========================================                     |
|       ___________                                                  |
|       < GreatHost >                                                |
|       -----------                                                  |
|              \   ^__^                                              |
|               \  (oo)\_______                                      |
|                  (__)\       )\/\                                  |
|                      ||----w |                                     |
|                      ||     ||                                     |
|                                                                    |
|    ===========================================                     |
|            www.GreatHost.in                                        |
|    ===========================================                     |
|                                                                    |
|       Welcome to the n8n One-Click Automated Installer             |
|  Installs: Docker + Compose + Postgres + n8n + Nginx + Let's Encrypt|
|____________________________________________________________________|
EOF

# -----------------------------
# Pre-checks
# -----------------------------
if [ "$(id -u)" -ne 0 ]; then
  fatal "Please run this script as root (sudo)."
fi

# Create log file
touch "$LOGFILE"
chmod 640 "$LOGFILE"

log "Starting GreatHost n8n installer"

# -----------------------------
# Ask inputs
# -----------------------------
read_input() {
  # domain
  while [ -z "${DOMAIN:-}" ]; do
    read -rp "Enter your domain (example.com) : " DOMAIN
  done

  # email
  while true; do
    read -rp "Enter admin email (for Let's Encrypt) : " EMAIL
    if [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
    echo "Please enter a valid email."
  done

  # basic auth user/pass
  read -rp "n8n UI username [default: admin]: " N8N_USER
  N8N_USER=${N8N_USER:-admin}

  while true; do
    read -rsp "n8n UI password: " p1; echo
    read -rsp "Confirm password: " p2; echo
    [ "$p1" = "$p2" ] && break
    echo "Passwords do not match. Try again."
  done
  N8N_PASS="$p1"

  # timezone optional
  read -rp "Timezone (optional, e.g. Asia/Kolkata) [press Enter to skip]: " TZ_INPUT
  TZ_INPUT=${TZ_INPUT:-}
}

read_input

log "User inputs: domain=$DOMAIN, email=$EMAIL, user=$N8N_USER, timezone=${TZ_INPUT:-'(none)'}"

# -----------------------------
# Detect OS family
# -----------------------------
OS=""
ID=""
VERSION_ID=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  ID=${ID,,}
  VERSION_ID=${VERSION_ID}
  if [[ "$ID" =~ ubuntu|debian ]]; then OS="debian"; fi
  if [[ "$ID" =~ almalinux|centos|rhel ]]; then OS="rhel"; fi
fi

[ -n "$OS" ] || fatal "Unsupported OS. This script supports Ubuntu/Debian and AlmaLinux/CentOS/RHEL."

log "Detected OS: $ID $VERSION_ID -> family: $OS"

# -----------------------------
# Helper: public IP / DNS check
# -----------------------------
get_public_ip() {
  # try multiple endpoints in case one fails
  ip=$(curl -fsS --max-time 8 https://ifconfig.co 2>/dev/null || true)
  ip=${ip:-$(curl -fsS --max-time 8 https://ipinfo.io/ip 2>/dev/null || true)}
  ip=${ip:-$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)}
  echo "$ip"
}

# validate DNS A record matches public IP
validate_dns() {
  log "Validating DNS A record for $DOMAIN"
  server_ip="$(get_public_ip)"
  if [ -z "$server_ip" ]; then
    log "Warning: Could not determine server public IP. Skipping DNS match check."
    return 0
  fi
  dns_ip="$(dig +short A "$DOMAIN" | head -n1 || true)"
  if [ -z "$dns_ip" ]; then
    log "Warning: DNS A record for $DOMAIN not found (yet). Please ensure domain points to server IP: $server_ip"
    return 1
  fi
  if [ "$dns_ip" != "$server_ip" ]; then
    log "Warning: DNS A record ($dns_ip) does not match server IP ($server_ip). Let's proceed but Certbot may fail until DNS updates."
    return 1
  fi
  log "DNS A record matches server IP: $server_ip"
  return 0
}

# -----------------------------
# System update & dependencies
# -----------------------------
log "Updating system packages and installing basic dependencies..."
if [ "$OS" = "debian" ]; then
  run apt update -y
  run apt upgrade -y
  run apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common dnsutils
else
  run dnf -y update
  run dnf install -y yum-utils epel-release dnsutils
fi

# -----------------------------
# Apply sysv patch (prevent docker freeze)
# -----------------------------
if [ -f "$SYSV_BIN" ]; then
  log "Temporarily backing up $SYSV_BIN to avoid installer freeze..."
  run mv "$SYSV_BIN" "$SYSV_BACKUP" || true
fi

# -----------------------------
# Install Docker (non-interactive)
# -----------------------------
log "Installing Docker (non-interactive)..."

if [ "$OS" = "debian" ]; then
  run apt remove -y docker docker-engine docker.io containerd runc || true

  run mkdir -p /etc/apt/keyrings
  run curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true

  arch=$(dpkg --print-architecture)
  release=$(lsb_release -cs)
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${release} stable
EOF
  run apt update -y
  # use noninteractive frontend to avoid prompts and possible sysv triggers
  DEBIAN_FRONTEND=noninteractive run apt install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin || true

else
  run dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
  run dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
  run dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
fi

# start & enable docker in a safe way
run systemctl daemon-reload || true
run systemctl enable --now docker || true

# restore sysv binary (if we backed up)
if [ -f "$SYSV_BACKUP" ]; then
  log "Restoring $SYSV_BIN"
  run mv "$SYSV_BACKUP" "$SYSV_BIN" 2>/dev/null || true
fi

# Add the invoking user (if not root) to docker group for convenience
if [ "$SUDO_USER" ]; then
  run usermod -aG docker "$SUDO_USER" || true
fi

# -----------------------------
# Create install dir and generate compose file
# -----------------------------
log "Creating install directory: $INSTALL_DIR"
run mkdir -p "$INSTALL_DIR"
run chown "$SUDO_USER":"$SUDO_USER" "$INSTALL_DIR" 2>/dev/null || true

# generate secure random password for postgres
randpass() { tr -dc A-Za-z0-9 </dev/urandom | head -c 20 || true; }

POSTGRES_PASSWORD="$(randpass)"
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"

log "Creating docker-compose.yml at $COMPOSE_FILE"
cat > "$COMPOSE_FILE" <<EOF
# GreatHost n8n docker-compose (auto-generated)
version: "3.8"

services:
  postgres:
    image: postgres:13
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - gh_n8n_postgres:/var/lib/postgresql/data
    networks:
      - gh_n8n_net

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=${POSTGRES_DB}
      - DB_POSTGRESDB_USERNAME=${POSTGRES_USER}
      - DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_PASS}
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${DOMAIN}
    ports:
      - "5678:5678"
    volumes:
      - gh_n8n_data:/home/node/.n8n
    depends_on:
      - postgres
    networks:
      - gh_n8n_net

volumes:
  gh_n8n_postgres:
  gh_n8n_data:

networks:
  gh_n8n_net:
    driver: bridge
EOF

run chown "$SUDO_USER":"$SUDO_USER" "$COMPOSE_FILE" 2>/dev/null || true

# -----------------------------
# Start docker compose stack
# -----------------------------
log "Starting n8n stack with docker compose..."
cd "$INSTALL_DIR" || fatal "Cannot cd to $INSTALL_DIR"

run docker compose pull || true
run docker compose up -d || fatal "Failed to start docker compose stack. Check $LOGFILE and 'docker compose logs'."

# quick check
sleep 4
run docker compose ps

# -----------------------------
# Firewall: open ports (80,443) and optionally 5678 for direct access
# -----------------------------
log "Configuring firewall (open 80/443)."

# ufw (Ubuntu) or firewalld (RHEL)
if command -v ufw >/dev/null 2>&1; then
  log "Detected ufw — allowing ports 80,443"
  run ufw allow 80/tcp || true
  run ufw allow 443/tcp || true
  # don't enable ufw if it wasn't enabled before
elif command -v firewall-cmd >/dev/null 2>&1; then
  log "Detected firewalld — opening ports 80,443"
  run firewall-cmd --permanent --add-service=http || true
  run firewall-cmd --permanent --add-service=https || true
  run firewall-cmd --reload || true
else
  log "No ufw/firewalld detected — please ensure ports 80/443 are allowed by your provider firewall."
fi

# -----------------------------
# SELinux: basic adjustments (RHEL-like)
# -----------------------------
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  log "SELinux active — applying httpd booleans for proxy"
  # allow httpd to make network connections (nginx -> proxy to 127.0.0.1)
  run setsebool -P httpd_can_network_connect 1 || true
  run setsebool -P httpd_can_network_connect_db 1 || true
  # set context for webroot
  run chcon -R -t httpd_sys_rw_content_t /var/www/html || true
fi

# -----------------------------
# NGINX + Certbot installation & config
# -----------------------------
log "Installing Nginx and Certbot..."

if [ "$OS" = "debian" ]; then
  run apt install -y nginx certbot python3-certbot-nginx || true
  run systemctl enable --now nginx || true
else
  run dnf install -y nginx || true
  run systemctl enable --now nginx || true

  # certbot via snap is more reliable on RHEL-like
  if ! command -v certbot >/dev/null 2>&1; then
    log "Installing snapd & certbot (snap) for certbot on RHEL-like"
    run dnf install -y snapd || true
    run systemctl enable --now snapd.socket || true
    run ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
    run snap install core || true
    run snap refresh core || true
    run snap install --classic certbot || true
    run ln -s /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
  fi
fi

# create minimal webroot for ACME challenges
run mkdir -p /var/www/html
run chown -R "$SUDO_USER":"$SUDO_USER" /var/www/html 2>/dev/null || true

# Nginx reverse proxy config (HTTP) - certbot will modify for HTTPS
NGINX_CONF="/etc/nginx/conf.d/greathost-n8n.conf"
log "Writing Nginx config: $NGINX_CONF"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};

    # allow ACME challenge path
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:5678/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

run nginx -t || fatal "nginx configuration test failed"
run systemctl reload nginx || true

# -----------------------------
# Validate DNS (best effort) before certbot
# -----------------------------
validate_dns || log "Proceeding even if DNS mismatch; certbot may fail until DNS records propagate."

# -----------------------------
# Obtain SSL cert with Certbot (nginx plugin preferred)
# -----------------------------
log "Requesting Let's Encrypt certificate for $DOMAIN"

if certbot --version >/dev/null 2>&1 && certbot --help | grep -q -- '--nginx'; then
  # if nginx plugin available
  run certbot --nginx -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect || true
else
  # fallback to webroot method (works if nginx is serving /.well-known)
  run certbot certonly --webroot -w /var/www/html -d "$DOMAIN" -d "www.$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" || true
  # create basic SSL-enabled nginx config if cert obtained
  if [ -f /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem ]; then
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:5678/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
    run nginx -t && run systemctl reload nginx || true
  else
    log "Certbot webroot method did not create cert - please check DNS and certbot logs in /var/log/letsencrypt"
  fi
fi

# -----------------------------
# Create cron for cert renewal (if certbot exists)
# -----------------------------
if command -v certbot >/dev/null 2>&1; then
  log "Creating cron job for certbot renew (daily check)"
  echo "0 3 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx" > /etc/cron.d/greathost-certbot-renew
fi

# -----------------------------
# Final health checks
# -----------------------------
log "Performing final health checks..."

# check containers
docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" | tee -a "$LOGFILE"

# check local access
if curl -fsS --max-time 6 http://127.0.0.1:5678/ >/dev/null 2>&1; then
  log "n8n responded on localhost:5678"
else
  log "Warning: n8n didn't respond on localhost:5678 — check 'docker compose logs n8n'"
fi

# check nginx/https
if curl -fsS --max-time 8 https://"${DOMAIN}"/ >/dev/null 2>&1; then
  log "HTTPS check OK for https://${DOMAIN}"
else
  log "HTTPS check failed or not yet available. If DNS propagation is recent, wait a few minutes and retry."
fi

# -----------------------------
# Output summary
# -----------------------------
cat <<EOF

${GREEN}============================================================${RESET}
${GREEN}🎉 GreatHost — n8n Installed Successfully!${RESET}
${YELLOW}Domain:${RESET} https://${DOMAIN}
${YELLOW}n8n UI Basic Auth:${RESET} ${N8N_USER} / (the password you entered)
${YELLOW}n8n Docker Compose path:${RESET} ${COMPOSE_FILE}
${YELLOW}Postgres (container):${RESET} DB=${POSTGRES_DB} USER=${POSTGRES_USER} PASS=${POSTGRES_PASSWORD}
${YELLOW}Logs:${RESET} sudo journalctl -u docker -n 200 ; docker compose logs -f n8n
${GREEN}============================================================${RESET}

EOF

log "Installation finished. See $LOGFILE for details."

# reminder about docker group
if [ -n "$SUDO_USER" ]; then
  echo
  echo "Note: You were added to the docker group (if applicable). Logout and log back in for docker group changes to take effect for user: $SUDO_USER"
fi

exit 0
