#!/bin/bash

if [ "$(id -u)" -ne 0 ]; then 
  echo "This script must be run as root or with sudo." >&2
  exit 1
fi

set -e

SSH_PORT=22
INSTALL_CADDY=false

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

    touch /etc/systemd/system/caddy.service
    cat <<EOF > /etc/systemd/system/caddy.service
# caddy.service
#
# For using Caddy with a config file.
#
# Make sure the ExecStart and ExecReload commands are correct
# for your installation.
#
# See https://caddyserver.com/docs/install for instructions.
#
# WARNING: This service does not use the --resume flag, so if you
# use the API to make changes, they will be overwritten by the
# Caddyfile next time the service is restarted. If you intend to
# use Caddy's API to configure it, add the --resume flag to the
# `caddy run` command or use the caddy-api.service file instead.

[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
EnvironmentFile=/etc/caddy/.env

[Install]
WantedBy=multi-user.target

EOF

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
