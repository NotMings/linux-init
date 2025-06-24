#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then 
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi

set -e

SSH_PORT=22
INSTALL_CADDY=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ssh) SSH_PORT="$2"; shift ;;
        --with-caddy) INSTALL_CADDY=true ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
    shift
done

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Invalid SSH port: $SSH_PORT. It must be a number between 1 and 65535." >&2
    exit 1
fi

apt update
apt upgrade -y

# Install packages
apt install -y \
    ufw \
    fail2ban \
    rsyslog \
    ca-certificates \
    curl \
    wget

# configure fail2ban
touch /etc/fail2ban/jail.local
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 3600
findtime = 300
maxretry = 5
banaction = iptables-allports
action = %(action_mwl)s

[sshd]
ignoreip = 127.0.0.1/8
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
backend = systemd

EOF

systemctl restart fail2ban

# configure ufw
yes | ufw enable
ufw allow $SSH_PORT
ufw allow 80
ufw allow 443

# install docker
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
apt update

apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

if [ "$INSTALL_CADDY" = true ]; then
    # install go
    wget https://go.dev/dl/go1.24.1.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.24.1.linux-amd64.tar.gz
    chmod -R 755 /usr/local/go
    rm -f go1.24.1.linux-amd64.tar.gz
    cat <<EOF >> /etc/profile
export PATH=$PATH:/usr/local/go/bin

EOF
    source /etc/profile

    # install caddy
    apt install -y debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-xcaddy.list
    apt update
    apt install -y xcaddy

    xcaddy build \
        --with github.com/caddy-dns/cloudflare \
        --output /usr/bin/caddy

    chmod 755 /usr/bin/caddy

    groupadd --system caddy
    useradd --system \
        --gid caddy \
        --create-home \
        --home-dir /var/lib/caddy \
        --shell /usr/sbin/nologin \
        --comment "Caddy web server" \
        caddy

    mkdir -p /etc/caddy
    touch /etc/caddy/Caddyfile
    touch /etc/caddy/.env

    cp "$SCRIPT_DIR/config_files/caddy.service" /etc/systemd/system/caddy.service

    chmod 644 /etc/systemd/system/caddy.service

    cat <<EOF > /etc/caddy/Caddyfile
{
    admin off
}

EOF

    systemctl daemon-reload
    systemctl enable caddy
    systemctl start caddy
fi
