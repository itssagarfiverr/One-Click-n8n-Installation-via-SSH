#!/bin/bash
# n8n One-Click Installer (Ubuntu / AlmaLinux 8/9/10)
# Installs Docker, Docker Compose, Postgres, n8n (Docker), Nginx reverse proxy, Certbot SSL
# Mirrors style of previous WordPress installer (prompts, banner, check_command)

set -euo pipefail

check_command() {
  if [ $? -ne 0 ]; then
    echo "An error occurred. Exiting."
    exit 1
  fi
}

# Disable motd scripts (best-effort)
if [ -d /etc/update-motd.d ]; then
  sudo chmod -x /etc/update-motd.d/* || true
fi

clear
cat <<'EOF'
 ____________________________________________________________________
|                                                                    |
|    ===========================================                     |
|    ::..𝐓𝐡i𝐬 𝐬𝐞𝐫𝐯𝐞r 𝐢𝐬 𝐬𝐞𝐭 𝐛𝐲 GreatHost.in...::               |
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
|   and Let's Encrypt SSL.                                            |
|                                                                    |
|   Please make sure your Domain exists and points to this server.   |
|                                                                    |
|____________________________________________________________________|
EOF

# Prompt inputs
user_input() {
  while [ -z "${domain:-}" ]; do
    read -rp "Your Domain (example.com): " domain
  done

  while true; do
    read -rp "Your Email Address (for Let's Encrypt & admin contact): " email
    if printf '%s\n' "$email" | grep -qE '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'; then
      break
    else
      echo "Please enter a valid E-Mail."
    fi
  done

  echo "n8n basic auth credentials (these protect the UI):"
  while [ -z "${n8n_user:-}" ]; do
    read -rp "n8n Username [default: admin]: " n8n_user
    n8n_user=${n8n_user:-admin}
  done

  while true; do
    read -rsp "n8n Password: " n8n_pass
    echo
    read -rsp "n8n Password (again): " n8n_pass2
    echo
    [ "${n8n_pass:-}" = "${n8n_pass2:-}" ] && break || echo "Passwords did not match. Try again."
  done

  # Optional: set timezone
  read -rp "Timezone (e.g. Asia/Kolkata) [optional]: " tz
  tz=${tz:-}
}

echo
echo "Please enter details to set up n8n:"
user_input

# Confirm
while true; do
  echo
  read -rp "Is everything correct? Domain=$domain Email=$email User=$n8n_user [Y/n]: " ok
  ok=${ok:-Y}
  case $ok in
    [Yy]* ) break;;
    [Nn]* ) unset domain email n8n_user n8n_pass tz; user_input;;
    * ) echo "Please answer y or n.";;
  esac
done

# Detect OS family
OS=""
OS_VERSION=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  ID_LIKE=${ID_LIKE:-}
  ID=${ID:-}
  VERSION_ID=${VERSION_ID:-}
  if echo "$ID" | grep -qiE 'ubuntu|debian'; then
    OS="debian"
  elif echo "$ID" | grep -qiE 'almalinux|rhel|centos'; then
    OS="rhel"
  elif echo "$ID_LIKE" | grep -qi 'debian'; then
    OS="debian"
  elif echo "$ID_LIKE" | grep -qi 'rhel'; then
    OS="rhel"
  fi
  OS_VERSION="$VERSION_ID"
fi

echo "Detected OS family: $OS (version $OS_VERSION)"

# Update & prerequisites
if [ "$OS" = "debian" ]; then
  sudo apt update -y
  check_command
  sudo apt -y upgrade
  check_command
  sudo apt -y install ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common
  check_command
elif [ "$OS" = "rhel" ]; then
  sudo dnf -y update
  check_command
  sudo dnf -y install -y yum-utils device-mapper-persistent-data lvm2
  check_command
  # epel for snap on RHEL-like
  sudo dnf -y install epel-release
  check_command
else
  echo "Unsupported OS. This installer supports Ubuntu/Debian and AlmaLinux/CentOS/RHEL families."
  exit 1
fi

# Install Docker
echo "Installing Docker Engine..."
if [ "$OS" = "debian" ]; then
  # Remove old versions
  sudo apt -y remove docker docker-engine docker.io containerd runc || true
  # Add Docker repo
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update -y
  sudo apt -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  check_command
elif [ "$OS" = "rhel" ]; then
  sudo dnf -y remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine || true
  sudo dnf -y config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
  check_command
fi

sudo systemctl enable --now docker
check_command

# Add current user to docker group (best effort)
if ! groups "$USER" | grep -q docker; then
  sudo usermod -aG docker "$USER" || true
fi

# Create n8n directory
INSTALL_DIR="/opt/n8n"
sudo mkdir -p "$INSTALL_DIR"
sudo chown "$USER":"$USER" "$INSTALL_DIR"

# Generate random DB password
generate_random_string() {
  tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16
}
POSTGRES_PASSWORD="$(generate_random_string)"
POSTGRES_USER="n8n"
POSTGRES_DB="n8n"

# Create docker-compose.yml
cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
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
      - n8n-postgres-data:/var/lib/postgresql/data
    networks:
      - n8n-network

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
      - N8N_BASIC_AUTH_USER=${n8n_user}
      - N8N_BASIC_AUTH_PASSWORD=${n8n_pass}
      - N8N_HOST=${domain}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_EDITOR_BASE_URL=https://${domain}
      - N8N_WWW_DOMAIN=${domain}
EOF

# If timezone provided, set envvar
if [ -n "${tz:-}" ]; then
  cat >> "$INSTALL_DIR/docker-compose.yml" <<EOF
      - GENERIC_TIMEZONE=${tz}
EOF
fi

cat >> "$INSTALL_DIR/docker-compose.yml" <<'EOF'
    ports:
      - "5678:5678"  # internal mapping; nginx will proxy but exposing helps debug
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

# Create .env (not strictly necessary, but helpful)
cat > "$INSTALL_DIR/.env" <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_DB=${POSTGRES_DB}
N8N_BASIC_AUTH_USER=${n8n_user}
# N8N_BASIC_AUTH_PASSWORD is intentionally not in plain .env for security
EOF

# Pull images and start stack
echo "Starting n8n docker stack..."
cd "$INSTALL_DIR"
sudo docker compose pull || true
sudo docker compose up -d
check_command

# Install Nginx and Certbot
echo "Installing Nginx and Certbot..."
if [ "$OS" = "debian" ]; then
  sudo apt -y install nginx
  check_command
  sudo systemctl enable --now nginx
  check_command
  # Use apt certbot with nginx plugin on Debian/Ubuntu
  sudo apt -y install certbot python3-certbot-nginx
  check_command
elif [ "$OS" = "rhel" ]; then
  sudo dnf -y install nginx
  check_command
  sudo systemctl enable --now nginx
  check_command
  # Install snapd (if not present) and certbot via snap for RHEL-like
  if ! command -v snap >/dev/null 2>&1; then
    sudo dnf -y install snapd
    check_command
    sudo systemctl enable --now snapd.socket
    check_command
    sudo ln -s /var/lib/snapd/snap /snap 2>/dev/null || true
    sudo snap install core || true
    sudo snap refresh core || true
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    sudo snap install --classic certbot
    sudo ln -s /snap/bin/certbot /usr/bin/certbot 2>/dev/null || true
  fi
fi

# Nginx reverse proxy config for domain
NGINX_CONF="/etc/nginx/conf.d/n8n-${domain}.conf"
sudo tee "$NGINX_CONF" > /dev/null <<EOF
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

sudo nginx -t
sudo systemctl reload nginx
check_command

# Firewall adjustments
if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --permanent --add-service=http
  sudo firewall-cmd --permanent --add-service=https
  sudo firewall-cmd --reload
fi

# SELinux (RHEL-like) adjustments (best-effort)
if command -v setenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || echo Disabled)" != "Disabled" ]; then
  sudo setsebool -P httpd_can_network_connect 1 || true
  sudo setsebool -P httpd_can_network_connect_db 1 || true
  sudo chcon -R -t httpd_sys_rw_content_t /var/www/html || true
fi

# Obtain Let's Encrypt certificate
echo
echo "Requesting Let's Encrypt certificate for ${domain}..."
if [ "$OS" = "debian" ]; then
  sudo certbot --nginx -d "${domain}" --non-interactive --agree-tos --email "${email}" --redirect || true
else
  # On RHEL-like using snap-installed certbot: use --nginx if plugin available, otherwise use standalone
  if certbot --help | grep -q -- '--nginx'; then
    sudo certbot --nginx -d "${domain}" --non-interactive --agree-tos --email "${email}" --redirect || true
  else
    # fallback: obtain cert using webroot
    sudo certbot certonly --webroot -w /var/www/html -d "${domain}" --non-interactive --agree-tos --email "${email}" || true
    # create basic SSL server block
    sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name ${domain};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${domain};
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;

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
    sudo nginx -t && sudo systemctl reload nginx || true
  fi
fi

# If cert obtained, restart nginx
sudo systemctl restart nginx || true

# Create a simple health-check page for ACME challenges
sudo mkdir -p /var/www/html
sudo chown -R "$USER":"$USER" /var/www/html

# Setup cron for certbot renew (if certbot exists)
if command -v certbot >/dev/null 2>&1; then
  echo "0 3 * * * /usr/bin/certbot renew --quiet && systemctl reload nginx" | sudo tee /etc/cron.d/certbot-renew >/dev/null
fi

# Final check: show status of docker containers
echo
echo "Docker containers status:"
sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"

# Output connection info
GREEN="\e[32m"
YELLOW="\e[33m"
RESET="\e[0m"

echo -e "${YELLOW}====================================================${RESET}"
echo -e "${GREEN}n8n installation complete!${RESET}"
echo
echo -e "Domain: ${domain}"
if sudo nginx -T 2>/dev/null | grep -q "ssl_certificate.*${domain}"; then
  echo -e "URL: https://${domain}"
else
  echo -e "URL: http://${domain} (HTTPS not configured / cert failed)"
fi
echo -e "n8n UI (basic auth enabled): /"
echo -e "Username: ${n8n_user}"
echo -e "Password: (the password you entered)"
echo
echo -e "Postgres DB:"
echo -e "  Host: postgres (container)"
echo -e "  Port: 5432"
echo -e "  Database: ${POSTGRES_DB}"
echo -e "  User: ${POSTGRES_USER}"
echo -e "  Password: ${POSTGRES_PASSWORD}"
echo
echo -e "To manage n8n stack:"
echo -e "  cd ${INSTALL_DIR} && sudo docker compose ps"
echo -e "  cd ${INSTALL_DIR} && sudo docker compose logs -f n8n"
echo -e "${YELLOW}====================================================${RESET}"
