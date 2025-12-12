#!/bin/bash
# n8n One-Click Installer (Ubuntu / AlmaLinux 8/9/10)
# Author: Ritik26 (Updated & Fixed Version)
# Installs Docker, Docker Compose, Postgres, n8n (Docker), Nginx reverse proxy, Certbot SSL

set -eo pipefail   # removed "-u" because it causes undefined variable crash

check_command() {
  if [ $? -ne 0 ]; then
    echo "An error occurred. Exiting."
    exit 1
  fi
}

# Disable motd scripts
if [ -d /etc/update-motd.d ]; then
  sudo chmod -x /etc/update-motd.d/* || true
fi

clear
cat <<'EOF'
 ____________________________________________________________________
|                                                                    |
|    ===========================================                     |
|    ::..This server is set by GreatHost.in...::                    |
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
|   Welcome to the n8n One-Click Installer.                          |
|   This will install n8n with Postgres, Docker, nginx reverse proxy |
|   and Let's Encrypt SSL.                                          |
|                                                                    |
|____________________________________________________________________|
EOF

### USER INPUTS ###
user_input() {
  while [ -z "${domain:-}" ]; do
    read -rp "Your Domain (example.com): " domain
  done

  while true; do
    read -rp "Your Email Address: " email
    if printf '%s\n' "$email" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
      break
    else
      echo "Invalid email!"
    fi
  done

  echo "n8n Basic Auth Details:"
  while [ -z "${n8n_user:-}" ]; do
    read -rp "n8n Username [default: admin]: " n8n_user
    n8n_user=${n8n_user:-admin}
  done

  while true; do
    read -rsp "n8n Password: " n8n_pass
    echo
    read -rsp "n8n Password (again): " n8n_pass2
    echo
    [ "$n8n_pass" = "$n8n_pass2" ] && break || echo "Passwords do not match!"
  done

  read -rp "Timezone (e.g. Asia/Kolkata) [optional]: " tz
  tz=${tz:-}
}

echo
echo "Please enter your details:"
user_input

# confirmation
while true; do
  read -rp "Is everything correct? [Y/n] " ok
  ok=${ok:-Y}
  case $ok in
    [Yy]*) break ;;
    [Nn]*) unset domain email n8n_user n8n_pass tz; user_input ;;
    *) echo "Type Y or N" ;;
  esac
done

### OS DETECT ###
OS=""
OS_VERSION=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [[ "$ID" =~ (ubuntu|debian) ]]; then OS="debian"; fi
  if [[ "$ID" =~ (almalinux|centos|rhel) ]]; then OS="rhel"; fi
  OS_VERSION="$VERSION_ID"
fi

echo "Detected OS: $OS ($OS_VERSION)"

### UPDATE SYSTEM ###
if [ "$OS" = "debian" ]; then
  sudo apt update -y && sudo apt upgrade -y
  sudo apt install -y ca-certificates curl gnupg software-properties-common
elif [ "$OS" = "rhel" ]; then
  sudo dnf update -y
  sudo dnf install -y yum-utils device-mapper-persistent-data lvm2 epel-release
else
  echo "Unsupported OS!"
  exit 1
fi

### INSTALL DOCKER ###
echo "Installing Docker Engine..."

if [ "$OS" = "debian" ]; then
  sudo apt remove -y docker docker-engine docker.io containerd runc || true
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" |
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt update -y
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true

elif [ "$OS" = "rhel" ]; then
  sudo dnf remove -y docker docker-client docker-common docker-latest || true
  sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || true
fi

sudo systemctl enable --now docker || true

# Add user to docker group
sudo usermod -aG docker "$USER" || true

### CREATE N8N DIR ###
INSTALL_DIR="/opt/n8n"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER":"$USER" "$INSTALL_DIR"

### RANDOM PASSWORD GENERATOR ###
generate_random_string() {
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

POSTGRES_PASSWORD="$(generate_random_string)"
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"

### DOCKER-COMPOSE FILE ###
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
      - n8n-postgres-data:/var/lib/postgresql/data
    networks:
      - n8n-network

  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: 5432
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USERNAME: ${POSTGRES_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_PASSWORD}
      N8N_BASIC_AUTH_ACTIVE: true
      N8N_BASIC_AUTH_USER: ${n8n_user}
      N8N_BASIC_AUTH_PASSWORD: ${n8n_pass}
      N8N_HOST: ${domain}
      N8N_PORT: 5678
      N8N_PROTOCOL: https
      N8N_EDITOR_BASE_URL: https://${domain}
EOF

if [ -n "$tz" ]; then
cat >> "$INSTALL_DIR/docker-compose.yml" <<EOF
      GENERIC_TIMEZONE: ${tz}
EOF
fi

cat >> "$INSTALL_DIR/docker-compose.yml" <<'EOF'
    ports:
      - "5678:5678"
    volumes:
      - n8n-data:/home/node/.n8n
    depends_on:
      - postgres
    networks:
      - n8n-network

volumes:
  n8n-postgres-data:
  n8n-data:

networks:
  n8n-network:
    driver: bridge
EOF

### START DOCKER STACK ###
cd "$INSTALL_DIR"
sudo docker compose pull || true
sudo docker compose up -d || true

### NGINX + CERTBOT ###
echo "Installing nginx + certbot..."

if [ "$OS" = "debian" ]; then
  sudo apt install -y nginx certbot python3-certbot-nginx
elif [ "$OS" = "rhel" ]; then
  sudo dnf install -y nginx
  sudo systemctl enable --now nginx
  sudo dnf install -y snapd
  sudo systemctl enable --now snapd.socket
  sudo ln -s /var/lib/snapd/snap /snap || true
  sudo snap install core || true
  sudo snap install --classic certbot || true
  sudo ln -s /snap/bin/certbot /usr/bin/certbot || true
fi

# nginx reverse proxy
NGINX_CONF="/etc/nginx/conf.d/n8n-${domain}.conf"
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass http://127.0.0.1:5678/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

sudo nginx -t && sudo systemctl reload nginx

### SSL ###
sudo certbot --nginx -d "$domain" -m "$email" --agree-tos --non-interactive --redirect || true

### FINAL MESSAGE ###
echo "===================================================="
echo "n8n Installation Completed!"
echo "Domain: $domain"
echo "URL: https://$domain"
echo "Username: $n8n_user"
echo "(Password you entered)"
echo "Postgres DB: $POSTGRES_DB"
echo "To manage n8n:"
echo "  cd $INSTALL_DIR && sudo docker compose ps"
echo "===================================================="
