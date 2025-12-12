#!/bin/bash
# GreatHost n8n One-Click Installer (Ubuntu / Debian / AlmaLinux / CentOS / RHEL)
# Includes sysv-install freeze fix + full ASCII cow banner

set -eo pipefail

check() { if [ $? -ne 0 ]; then echo "❌ Error occurred. Exiting."; exit 1; fi; }

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
|  Installs: Docker + Compose + Postgres + n8n + Nginx + SSL         |
|____________________________________________________________________|
EOF

echo

#########################################
# USER INPUT
#########################################

ask_inputs() {
  while [ -z "${domain:-}" ]; do
    read -rp "Your Domain (example.com): " domain
  done

  while true; do
    read -rp "Admin Email (for SSL): " email
    if echo "$email" | grep -Eq '^[^@]+@[^@]+\.[^@]+$'; then break; fi
    echo "Invalid Email ❌"
  done

  read -rp "n8n Username [default admin]: " n8n_user
  n8n_user=${n8n_user:-admin}

  while true; do
    read -rsp "n8n Password: " p1; echo
    read -rsp "Confirm Password: " p2; echo
    [[ "$p1" == "$p2" ]] && break
    echo "Passwords do not match ❌"
  done
  n8n_pass="$p1"

  read -rp "Timezone (optional, example: Asia/Kolkata): " tz
  tz=${tz:-}
}

ask_inputs

while true; do
  read -rp "Proceed with installation? (Y/n): " ok
  ok=${ok:-Y}
  case $ok in
    [Yy]*) break ;;
    [Nn]*) unset domain email n8n_user n8n_pass tz; ask_inputs ;;
    *) echo "Type Y or N" ;;
  esac
done

#########################################
# OS DETECTION
#########################################

. /etc/os-release

if echo "$ID" | grep -Eq "ubuntu|debian"; then OS=debian; fi
if echo "$ID" | grep -Eq "almalinux|centos|rhel"; then OS=rhel; fi

echo "Detected OS: $OS"

#########################################
# SYSTEM UPDATE
#########################################

if [ "$OS" = "debian" ]; then
  apt update -y && apt upgrade -y
  apt install -y ca-certificates curl gnupg lsb-release software-properties-common
else
  dnf update -y
  dnf install -y yum-utils epel-release device-mapper-persistent-data lvm2
fi

#########################################
# SYSV INSTALL FIX (PREVENT DOCKER HANG)
#########################################

echo "Applying Docker freeze patch..."
if [ -f /usr/lib/systemd/systemd-sysv-install ]; then
  mv /usr/lib/systemd/systemd-sysv-install /usr/lib/systemd/systemd-sysv-install.bak 2>/dev/null || true
fi

#########################################
# INSTALL DOCKER
#########################################

echo "Installing Docker..."

if [ "$OS" = "debian" ]; then
  apt remove -y docker docker-engine docker.io containerd runc || true

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

  apt update -y
  DEBIAN_FRONTEND=noninteractive apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true

else
  dnf remove -y docker docker-client docker-common docker-latest || true
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
fi

systemctl daemon-reload || true
systemctl enable docker || true
systemctl start docker || true

echo "Restoring sysv installer..."
mv /usr/lib/systemd/systemd-sysv-install.bak /usr/lib/systemd/systemd-sysv-install 2>/dev/null || true

echo "✅ Docker Installed Successfully!"


#########################################
# N8N + POSTGRES INSTALL
#########################################

INSTALL_DIR="/opt/greathost-n8n"
mkdir -p "$INSTALL_DIR"

rand() { tr -dc A-Za-z0-9 </dev/urandom | head -c 16; }

POSTGRES_PASSWORD=$(rand)
POSTGRES_USER=n8n
POSTGRES_DB=n8n

cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
version: "3.8"

services:
  postgres:
    image: postgres:13
    restart: unless-stopped
    environment:
      POSTGRES_USER: $POSTGRES_USER
      POSTGRES_PASSWORD: $POSTGRES_PASSWORD
      POSTGRES_DB: $POSTGRES_DB
    volumes:
      - data-postgres:/var/lib/postgresql/data
    networks:
      - gh-net

  n8n:
    image: n8nio/n8n
    restart: unless-stopped
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: $POSTGRES_DB
      DB_POSTGRESDB_USERNAME: $POSTGRES_USER
      DB_POSTGRESDB_PASSWORD: $POSTGRES_PASSWORD
      N8N_BASIC_AUTH_ACTIVE: true
      N8N_BASIC_AUTH_USER: "$n8n_user"
      N8N_BASIC_AUTH_PASSWORD: "$n8n_pass"
      N8N_HOST: "$domain"
      N8N_PROTOCOL: https
      N8N_PORT: 5678
      N8N_EDITOR_BASE_URL: "https://$domain"
EOF

if [ -n "$tz" ]; then
  echo "      GENERIC_TIMEZONE: $tz" >> "$INSTALL_DIR/docker-compose.yml"
fi

cat >> "$INSTALL_DIR/docker-compose.yml" <<'EOF'
    ports:
      - "5678:5678"
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
docker compose pull || true
docker compose up -d || true


#########################################
# NGINX + SSL
#########################################

echo "Installing NGINX + SSL..."

if [ "$OS" = "debian" ]; then
  apt install -y nginx certbot python3-certbot-nginx
else
  dnf install -y nginx
  systemctl enable --now nginx
  dnf install -y snapd
  systemctl enable --now snapd.socket
  ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
  snap install core || true
  snap install --classic certbot || true
  ln -s /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
fi

NGINX_CONF="/etc/nginx/conf.d/greathost-n8n.conf"

cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name $domain;

    location / {
        proxy_pass http://127.0.0.1:5678/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

nginx -t && systemctl reload nginx

certbot --nginx -d "$domain" -m "$email" --agree-tos --non-interactive --redirect || true

#########################################
# SUCCESS MESSAGE
#########################################

clear
cat <<EOF

===========================================================
🎉 GREAT HOST — N8N INSTALLED SUCCESSFULLY!
===========================================================

🌍 Domain: https://$domain
👤 Username: $n8n_user
🔐 Password: (hidden)
📦 Install Directory: $INSTALL_DIR

🐳 Manage n8n Containers:
   cd $INSTALL_DIR && docker compose ps
   cd $INSTALL_DIR && docker compose logs -f n8n

🗄 Postgres:
   DB: $POSTGRES_DB
   User: $POSTGRES_USER
   Pass: $POSTGRES_PASSWORD

===========================================================
Thank you for using GreatHost.in 🚀
===========================================================

EOF
