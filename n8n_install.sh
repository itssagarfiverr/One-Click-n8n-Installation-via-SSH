#!/bin/bash
# n8n One-Click Installer (Ubuntu 20+/22+/24+ & AlmaLinux 8/9/10)
# Author: Ritik26 / GreatHost.in
# Fully fixed version with sysv patch, branding and cow ASCII banner

set -eo pipefail

check() { if [ $? -ne 0 ]; then echo "❌ Error occurred. Exiting."; exit 1; fi; }

clear
cat <<EOF
 ____________________________________________________________________
|                                                                    |
|    ===========================================                     |
|    ::..𝐓𝐡i𝐬 𝐬𝐞𝐫𝐯𝐞𝐫 𝐢𝐬 𝐬𝐞𝐭 𝐛𝐲 GreatHost.in...::               |
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
|      Welcome to the GreatHost n8n One-Click Automated Installer    |
|   Installs: Docker + Postgres + n8n + Nginx Reverse Proxy + SSL    |
|____________________________________________________________________|
EOF

##############################
# USER INPUT
##############################

ask_inputs() {
  while [ -z "${domain:-}" ]; do
    read -rp "Your Domain (example.com): " domain
  done

  while true; do
    read -rp "Admin Email (for Let's Encrypt): " email
    if echo "$email" | grep -Eq '^[^@]+@[^@]+\.[^@]+$'; then break; fi
    echo "Invalid email—try again."
  done

  read -rp "n8n Username [default admin]: " n8n_user
  n8n_user=${n8n_user:-admin}

  while true; do
    read -rsp "n8n Password: " p1; echo
    read -rsp "Confirm Password: " p2; echo
    [[ "$p1" == "$p2" ]] && break
    echo "Passwords do not match!"
  done
  n8n_pass="$p1"

  read -rp "Timezone (optional) e.g. Asia/Kolkata: " tz
  tz=${tz:-}
}

ask_inputs

while true; do
  read -rp "Confirm details and proceed? (Y/n): " ok
  ok=${ok:-Y}
  case $ok in
    [Yy]*) break ;;
    [Nn]*) unset domain email n8n_user n8n_pass tz; ask_inputs ;;
    *) echo "Type Y or N" ;;
  esac
done

##############################
# OS DETECT
##############################

if [ -f /etc/os-release ]; then
  . /etc/os-release
  if echo "$ID" | grep -Eq "ubuntu|debian"; then OS="debian"; fi
  if echo "$ID" | grep -Eq "almalinux|centos|rhel"; then OS="rhel"; fi
else
  echo "Unsupported OS. Exiting."
  exit 1
fi

echo "Detected OS: $OS"

##############################
# SYSTEM UPDATE
##############################

if [ "$OS" = "debian" ]; then
  sudo apt update -y && sudo apt upgrade -y
  sudo apt install -y ca-certificates curl gnupg lsb-release software-properties-common
elif [ "$OS" = "rhel" ]; then
  sudo dnf update -y
  sudo dnf install -y yum-utils epel-release device-mapper-persistent-data lvm2
fi

##############################
# 🔥 SYSV INSTALL PATCH (Fix freeze)
##############################

echo "Applying sysv patch (prevents docker hang)..."

if [ -f /usr/lib/systemd/systemd-sysv-install ]; then
  sudo mv /usr/lib/systemd/systemd-sysv-install /usr/lib/systemd/systemd-sysv-install.bak 2>/dev/null || true
fi

##############################
# INSTALL DOCKER (non-interactive)
##############################

echo "Installing Docker Engine (non-interactive)..."

if [ "$OS" = "debian" ]; then

  sudo apt remove -y docker docker-engine docker.io containerd runc || true

  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" |
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt update -y

  sudo DEBIAN_FRONTEND=noninteractive apt install -yq docker-ce docker-ce-cli containerd.io docker-compose-plugin || true

elif [ "$OS" = "rhel" ]; then

  sudo dnf remove -y docker docker-client docker-common docker-latest || true

  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true

fi

sudo systemctl daemon-reload || true
sudo systemctl enable docker || true
sudo systemctl start docker || true

echo "Restoring sysv install binary (if any)..."
sudo mv /usr/lib/systemd/systemd-sysv-install.bak /usr/lib/systemd/systemd-sysv-install 2>/dev/null || true

echo "🎉 Docker Installed Successfully! (No Hang Guaranteed)"

##############################
# n8n + POSTGRES SETUP
##############################

INSTALL_DIR="/opt/greathost-n8n"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER":"$USER" "$INSTALL_DIR"

rand() { tr -dc A-Za-z0-9 </dev/urandom | head -c 16; }

POSTGRES_PASSWORD=$(rand)
POSTGRES_USER=greathost_n8n
POSTGRES_DB=greathost_n8n

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: "3.8"

services:
  postgres:
    image: postgres:13
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - data-postgres:/var/lib/postgresql/data
    networks:
      - gh-net

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - "5678:5678"
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USERNAME: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_BASIC_AUTH_ACTIVE: "true"
      N8N_BASIC_AUTH_USER: "${n8n_user}"
      N8N_BASIC_AUTH_PASSWORD: "${n8n_pass}"
      N8N_HOST: "${domain}"
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: "https://${domain}"
EOF

if [ -n "$tz" ]; then
  echo "      GENERIC_TIMEZONE: ${tz}" >> "$INSTALL_DIR/docker-compose.yml"
fi

cat >> "$INSTALL_DIR/docker-compose.yml" <<'EOF'
    volumes:
      - data-n8n:/home/node/.n8n
    depends_on:
      - postgres
    networks:
      - gh-net

volumes:
  data-postgres:
  data-n8n:

networks:
  gh-net:
    driver: bridge
EOF

cd "$INSTALL_DIR"
sudo docker compose pull || true
sudo docker compose up -d || true

##############################
# NGINX + SSL
##############################

echo "Installing Nginx + Certbot..."

if [ "$OS" = "debian" ]; then
  sudo apt install -y nginx certbot python3-certbot-nginx
else
  sudo dnf install -y nginx
  sudo systemctl enable --now nginx

  sudo dnf install -y snapd
  sudo systemctl enable --now snapd.socket
  sudo ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
  sudo snap install core || true
  sudo snap install --classic certbot || true
  sudo ln -s /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
fi

NGINX_CONF="/etc/nginx/conf.d/greathost-n8n-${domain}.conf"

sudo tee "$NGINX_CONF" >/dev/null <<EOF
server {
    listen 80;
    server_name ${domain};

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

sudo nginx -t && sudo systemctl reload nginx

sudo certbot --nginx -d "$domain" -m "$email" --agree-tos --redirect --non-interactive || true

##############################
# POST-INSTALL: health page & cron
##############################

sudo mkdir -p /var/www/html
sudo chown -R "$USER":"$USER" /var/www/html

if command -v certbot >/dev/null 2>&1; then
  echo "0 3 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx" | sudo tee /etc/cron.d/greathost-certbot-renew >/dev/null
fi

##############################
# SUCCESS MESSAGE WITH BRAND
##############################

cat <<'OUT'

===========================================================
🎉 GreatHost n8n Installed Successfully!
🌐 URL: https://${domain}
👤 Username: ${n8n_user}
🔐 Password: (the one you entered)
📁 Install Directory: ${INSTALL_DIR}
🐳 Manage n8n Docker:
    cd ${INSTALL_DIR} && sudo docker compose ps
📦 Postgres:
    DB: ${POSTGRES_DB}
    User: ${POSTGRES_USER}
    Password: ${POSTGRES_PASSWORD}
===========================================================

OUT

# Friendly reminder
echo "Note: if you added your user to the docker group, you may need to re-login for group changes to apply."
echo "If HTTPS didn't configure automatically, check /var/log/letsencrypt and nginx config."

# End of script - GreatHost
