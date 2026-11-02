#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config_files"
readonly SCRIPT_DIR CONFIG_DIR

SSH_PORT_SET=false
SSH_PORTS=()
SSH_PORT_LIST=""

UPGRADE_SYSTEM=false
INSTALL_FAIL2BAN=false
INSTALL_DOCKER=false
INSTALL_CADDY=false
REBOOT_REQUIRED=false

CADDY_MODULES=()
CADDY_ARCH=""
CADDY_ARM=""
CADDY_TEMP_DIR=""
UPGRADE_TEMP_DIR=""
UPGRADE_BACKUP_DIR=""

usage() {
    cat <<'EOF'
Usage: sudo bash ubuntu/init.sh [options]

Options:
  --ssh PORT [PORT ...]     Override detected SSH ports; does not change sshd.
                            Accepts spaces, commas and repeated --ssh options.
  --upgrade-system          Upgrade Ubuntu along its official release channel (default: false).
  --with-fail2ban           Install and configure Fail2ban (default: false).
  --with-docker             Install Docker Engine, Buildx and Compose (default: false).
  --with-caddy              Download standard Caddy (default: false).
  --with-caddy-MODULE       Download Caddy with a module; repeat to combine modules.
                            Short names select github.com/caddy-dns/MODULE.
                            Full Go package paths are also accepted after the prefix.
  -h, --help                Show this help.

Examples:
  sudo bash ubuntu/init.sh --ssh 22 2222
  sudo bash ubuntu/init.sh --upgrade-system
  sudo bash ubuntu/init.sh --with-fail2ban
  sudo bash ubuntu/init.sh --with-docker
  sudo bash ubuntu/init.sh --with-caddy-cloudflare
  sudo bash ubuntu/init.sh --with-caddy-cloudflare --with-caddy-route53
  sudo bash ubuntu/init.sh --with-caddy-github.com/mholt/caddy-l4
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

cleanup() {
    local status=$?

    if [[ -n "$CADDY_TEMP_DIR" ]]; then
        rm -rf -- "$CADDY_TEMP_DIR"
    fi
    if [[ -n "$UPGRADE_TEMP_DIR" ]]; then
        rm -rf -- "$UPGRADE_TEMP_DIR"
    fi
    if (( status != 0 )) && [[ -n "$UPGRADE_BACKUP_DIR" ]]; then
        echo "Upgrade stopped. Configuration backup: $UPGRADE_BACKUP_DIR." \
            "Inspect APT/dpkg state before restoring sources." >&2
    fi
    return "$status"
}

add_ssh_port() {
    local port="$1" existing

    [[ "$port" =~ ^[0-9]{1,5}$ ]] || die "Invalid SSH port: $port"
    port=$((10#$port))
    (( port >= 1 && port <= 65535 )) ||
        die "SSH port must be between 1 and 65535."

    for existing in "${SSH_PORTS[@]}"; do
        [[ "$existing" != "$port" ]] || return 0
    done
    SSH_PORTS+=("$port")
}

add_caddy_module() {
    local module="$1" existing

    if [[ "$module" != */* ]]; then
        [[ "$module" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
            die "Invalid Caddy module: $module"
        module="github.com/caddy-dns/$module"
    else
        [[ "$module" =~ ^[a-zA-Z0-9][a-zA-Z0-9._~/-]+(@[a-zA-Z0-9._+/-]+)?$ ]] ||
            die "Invalid Caddy package: $module"
    fi

    INSTALL_CADDY=true
    for existing in "${CADDY_MODULES[@]}"; do
        [[ "$existing" != "$module" ]] || return 0
    done
    CADDY_MODULES+=("$module")
}

parse_arguments() {
    local port
    local -a supplied_ports

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh)
                [[ $# -ge 2 && "$2" != -* ]] ||
                    die "--ssh requires at least one port."
                SSH_PORT_SET=true
                shift
                while [[ $# -gt 0 && "$1" != --* && "$1" != -h ]]; do
                    [[ "$1" =~ ^[0-9]+(,[0-9]+)*$ ]] ||
                        die "Invalid SSH port list: $1"
                    IFS=, read -r -a supplied_ports <<< "$1"
                    for port in "${supplied_ports[@]}"; do
                        add_ssh_port "$port"
                    done
                    shift
                done
                ;;
            --upgrade-system)
                UPGRADE_SYSTEM=true
                shift
                ;;
            --with-fail2ban)
                INSTALL_FAIL2BAN=true
                shift
                ;;
            --with-docker)
                INSTALL_DOCKER=true
                shift
                ;;
            --with-caddy)
                INSTALL_CADDY=true
                shift
                ;;
            --with-caddy-*)
                add_caddy_module "${1#--with-caddy-}"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1. Use --help for usage."
                ;;
        esac
    done
}

check_environment() {
    [[ "$(id -u)" -eq 0 ]] ||
        die "This script must be run as root or with sudo."

    # shellcheck source=/etc/os-release
    source /etc/os-release
    [[ "$ID" == ubuntu ]] || die "This script only supports Ubuntu."
    VERSION_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
}

detect_ssh_ports() {
    local output ports="" port sshd_bin

    # Prefer ports actually listened on by sshd, including command-line overrides.
    if command -v ss > /dev/null && output="$(ss -H -ltnp 2>/dev/null)"; then
        ports="$(awk '
            /"sshd"/ {
                address = $4
                sub(/^.*:/, "", address)
                print address
            }
        ' <<< "$output" | sort -un)"
    fi

    # Socket activation may leave systemd, rather than sshd, owning the listener.
    if [[ -z "$ports" ]] && systemctl is-active --quiet ssh.socket; then
        output="$(systemctl show ssh.socket --property=Listen --value)"
        ports="$(awk '{
            for (i = 1; i < NF; i++) {
                if ($(i + 1) == "(Stream)") {
                    address = $i
                    sub(/^.*:/, "", address)
                    if (address ~ /^[0-9]+$/) print address
                }
            }
        }' <<< "$output" | sort -un)"
    fi

    if [[ -z "$ports" ]]; then
        sshd_bin="$(command -v sshd || true)"
        if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then
            sshd_bin=/usr/sbin/sshd
        fi
        [[ -n "$sshd_bin" ]] ||
            die "Cannot find sshd to detect SSH ports. Specify --ssh PORT."
        output="$("$sshd_bin" -T)" ||
            die "Cannot read effective SSH configuration. Specify --ssh PORT."
        ports="$(awk '
            $1 == "listenaddress" {
                address = $2
                sub(/^.*:/, "", address)
                print address
                found = 1
            }
            $1 == "port" { ports = ports $2 "\n" }
            END { if (!found) printf "%s", ports }
        ' <<< "$output" | sort -un)"
    fi

    [[ -n "$ports" ]] || die "Cannot detect SSH ports. Specify --ssh PORT."

    while IFS= read -r port; do
        [[ -z "$port" ]] || add_ssh_port "$port"
    done <<< "$ports"
}

check_install_options() {
    local architecture

    if [[ "$INSTALL_DOCKER" == true ]]; then
        [[ -n "${VERSION_CODENAME:-}" ]] ||
            die "Cannot determine the Ubuntu release codename."
    fi

    if [[ "$INSTALL_CADDY" == true ]]; then
        [[ -f "$CONFIG_DIR/caddy.service" ]] ||
            die "Missing shared Caddy service: $CONFIG_DIR/caddy.service"
        architecture="$(dpkg --print-architecture)"
        case "$architecture" in
            amd64) CADDY_ARCH=amd64 ;;
            arm64) CADDY_ARCH=arm64 ;;
            armhf)
                CADDY_ARCH=arm
                CADDY_ARM=7
                ;;
            armel)
                CADDY_ARCH=arm
                CADDY_ARM=5
                ;;
            i386) CADDY_ARCH=386 ;;
            ppc64el) CADDY_ARCH=ppc64le ;;
            riscv64) CADDY_ARCH=riscv64 ;;
            s390x) CADDY_ARCH=s390x ;;
            *) die "Unsupported architecture for Caddy: $architecture" ;;
        esac
    fi
}

is_default_ubuntu_pro_preference() {
    local preference="$1" package expected_md5 actual_md5

    case "$preference" in
        /etc/apt/preferences.d/ubuntu-pro-esm-apps | \
            /etc/apt/preferences.d/ubuntu-pro-esm-infra) ;;
        *) return 1 ;;
    esac

    actual_md5="$(md5sum -- "$preference")" || return 1
    actual_md5="${actual_md5%% *}"
    for package in ubuntu-pro-client ubuntu-advantage-tools; do
        expected_md5="$(
            dpkg-query -W -f='${Conffiles}\n' "$package" 2>/dev/null |
                awk -v path="$preference" '$1 == path && NF == 2 { print $2; exit }'
        )" || continue
        [[ "$expected_md5" =~ ^[0-9a-f]{32}$ ]] || continue
        if [[ "$actual_md5" == "$expected_md5" ]]; then
            return 0
        fi
    done
    return 1
}

upgrade_system() {
    local previous_version channel metadata_url check_output audit holds source_file
    local check_status=0

    [[ "${VERSION_ID:-}" =~ ^[0-9]{2}\.(04|10)$ && "${VERSION_CODENAME:-}" =~ ^[a-z]+$ ]] ||
        die "Cannot determine the current Ubuntu release."
    previous_version="$VERSION_ID"
    audit="$(dpkg --audit)"
    [[ -z "$audit" ]] || die "Resolve dpkg package errors before upgrading: $audit"
    holds="$(apt-mark showhold)"
    [[ -z "$holds" ]] || die "Review held packages before upgrading: $holds"

    for source_file in /etc/apt/preferences /etc/apt/preferences.d/*; do
        [[ -f "$source_file" ]] || continue
        # Ubuntu Pro ships these preferences even when ESM is not enabled.
        if is_default_ubuntu_pro_preference "$source_file"; then
            echo "Keeping unmodified Ubuntu Pro preference: $source_file"
            continue
        fi
        if grep -Eq '^[[:space:]]*[^#[:space:]]' "$source_file"; then
            die "Review APT pinning before upgrading: $source_file"
        fi
    done

    install -d -m 0700 /var/backups/linux-init
    UPGRADE_BACKUP_DIR="$(mktemp -d "/var/backups/linux-init/ubuntu-$previous_version-upgrade.XXXXXX")"
    cp -a /etc/apt "$UPGRADE_BACKUP_DIR/apt"
    cp -L /etc/os-release "$UPGRADE_BACKUP_DIR/os-release"
    dpkg --get-selections > "$UPGRADE_BACKUP_DIR/package-selections.txt"
    if [[ -f /var/lib/dpkg/status ]]; then
        cp -a /var/lib/dpkg/status "$UPGRADE_BACKUP_DIR/dpkg-status"
    fi
    if [[ -d /etc/update-manager ]]; then
        cp -a /etc/update-manager "$UPGRADE_BACKUP_DIR/update-manager"
    fi
    echo "Upgrade configuration backup: $UPGRADE_BACKUP_DIR"

    apt-get -o APT::Update::Error-Mode=any update
    apt-get install -y ca-certificates curl update-manager-core ubuntu-release-upgrader-core

    # Follow Ubuntu's supported upgrade channel; never request a development release.
    channel=normal
    metadata_url=https://changelogs.ubuntu.com/meta-release
    if [[ "${VERSION:-}" == *LTS* ]]; then
        channel=lts
        metadata_url=https://changelogs.ubuntu.com/meta-release-lts
    fi
    if grep -Eq '^[[:space:]]*Prompt[[:space:]]*=' /etc/update-manager/release-upgrades; then
        sed -i "s/^[[:space:]]*Prompt[[:space:]]*=.*/Prompt=$channel/" \
            /etc/update-manager/release-upgrades
    else
        printf '\nPrompt=%s\n' "$channel" >> /etc/update-manager/release-upgrades
    fi

    # Fail explicitly on connectivity errors instead of reporting no upgrade available.
    UPGRADE_TEMP_DIR="$(mktemp -d)"
    curl --fail --show-error --location \
        --retry 3 --connect-timeout 15 --max-time 60 \
        "$metadata_url" --output "$UPGRADE_TEMP_DIR/meta-release"
    grep -q '^Dist:' "$UPGRADE_TEMP_DIR/meta-release" ||
        die "Invalid Ubuntu release metadata."
    check_output="$(LC_ALL=C do-release-upgrade --mode=server --check-dist-upgrade-only 2>&1)" ||
        check_status=$?
    printf '%s\n' "$check_output"
    if (( check_status != 0 )); then
        if grep -Eiq 'Failed to|Traceback|ERROR:|cannot connect|ConnectionError' <<< "$check_output"; then
            die "Ubuntu release availability check failed."
        fi
        case "$check_output" in
            *"No new release found."* | *"There is no development version of an LTS available."*)
                echo "No release upgrade is currently offered on Ubuntu's $channel channel."
                return 0
                ;;
            *) die "Ubuntu release availability check failed (exit $check_status)." ;;
        esac
    fi

    # Complete phased updates too, as required by the official release upgrader.
    apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y
    if [[ -f /var/run/reboot-required ]]; then
        die "Current-release updates require a reboot. Run sudo reboot, then rerun --upgrade-system."
    fi

    echo "Upgrading Ubuntu $previous_version through the official $channel channel."
    if [[ "${DEBIAN_FRONTEND:-}" == noninteractive ]]; then
        do-release-upgrade --mode=server --frontend=DistUpgradeViewNonInteractive
    else
        do-release-upgrade --mode=server
    fi
    audit="$(dpkg --audit)"
    [[ -z "$audit" ]] || die "Release upgrade left dpkg errors: $audit"

    # Refresh the codename before configuring the optional Docker repository.
    source /etc/os-release
    VERSION_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    dpkg --compare-versions "$VERSION_ID" gt "$previous_version" ||
        die "Release upgrade did not finish; inspect /var/log/dist-upgrade and the configuration backup."
    REBOOT_REQUIRED=true
    echo "Ubuntu release upgrade completed. Review disabled third-party sources and reboot after initialization."
}

install_base_packages() {
    apt-get update
    apt-get upgrade -y
    apt-get install -y ufw ca-certificates curl
}

configure_firewall() {
    local port

    # Allow SSH before enabling the firewall to avoid locking out remote access.
    for port in "${SSH_PORTS[@]}"; do
        ufw allow "$port/tcp"
    done
    if [[ "$INSTALL_CADDY" == true ]]; then
        ufw allow 80
        ufw allow 443
    fi
    ufw --force enable
}

install_fail2ban() {
    apt-get install -y fail2ban python3-systemd iptables

    # Use a separate jail file to preserve existing Fail2ban configuration.
    install -d -m 0755 /etc/fail2ban/jail.d
    cat > /etc/fail2ban/jail.d/99-linux-init.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT_LIST
filter = sshd
backend = systemd
ignoreip = 127.0.0.1/8 ::1
bantime = 3600
findtime = 300
maxretry = 5
banaction = iptables-allports
action = %(action_)s
EOF
    fail2ban-client -t
    systemctl enable fail2ban
    systemctl restart fail2ban
}

install_docker() {
    install -m 0755 -d /etc/apt/keyrings
    curl --fail --show-error --location \
        --retry 3 --connect-timeout 15 \
        https://download.docker.com/linux/ubuntu/gpg \
        --output /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc

    printf 'deb [arch=%s signed-by=%s] %s %s stable\n' \
        "$(dpkg --print-architecture)" /etc/apt/keyrings/docker.asc \
        https://download.docker.com/linux/ubuntu "$VERSION_CODENAME" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
    systemctl enable --now docker
}

install_caddy() {
    local module
    local -a download_args

    # Stage on the same filesystem so replacing a running binary is atomic.
    CADDY_TEMP_DIR="$(mktemp -d /usr/bin/.caddy-download.XXXXXX)"
    download_args=(
        --data-urlencode os=linux
        --data-urlencode "arch=$CADDY_ARCH"
    )
    if [[ -n "$CADDY_ARM" ]]; then
        download_args+=(--data-urlencode "arm=$CADDY_ARM")
    fi
    for module in "${CADDY_MODULES[@]}"; do
        download_args+=(--data-urlencode "p=$module")
    done

    echo "Downloading Caddy from caddyserver.com for $CADDY_ARCH..."
    curl --fail --show-error --location \
        --retry 3 --connect-timeout 15 --max-time 600 \
        --get "${download_args[@]}" \
        https://caddyserver.com/api/download \
        --output "$CADDY_TEMP_DIR/caddy"
    chmod 0755 "$CADDY_TEMP_DIR/caddy"
    "$CADDY_TEMP_DIR/caddy" version
    "$CADDY_TEMP_DIR/caddy" list-modules --skip-standard --versions

    if ! getent group caddy > /dev/null; then
        groupadd --system caddy
    fi
    if ! id -u caddy > /dev/null 2>&1; then
        useradd --system \
            --gid caddy \
            --create-home \
            --home-dir /var/lib/caddy \
            --shell /usr/sbin/nologin \
            --comment "Caddy web server" \
            caddy
    fi

    install -d -m 0755 /etc/caddy
    install -d -o caddy -g caddy -m 0750 /var/lib/caddy

    if [[ ! -e /etc/caddy/Caddyfile ]]; then
        # Keep the local admin endpoint enabled for systemctl reload caddy.
        printf '# Add your site configuration here.\n' > /etc/caddy/Caddyfile
        chmod 0644 /etc/caddy/Caddyfile
    fi
    if [[ ! -e /etc/caddy/.env ]]; then
        install -m 0600 /dev/null /etc/caddy/.env
    fi

    mv -f -- "$CADDY_TEMP_DIR/caddy" /usr/bin/caddy
    install -m 0644 "$CONFIG_DIR/caddy.service" \
        /etc/systemd/system/caddy.service
    systemctl daemon-reload
    systemctl enable caddy
    # Restart also activates a newly downloaded binary on subsequent runs.
    systemctl restart caddy
}

main() {
    parse_arguments "$@"
    check_environment

    if [[ "$SSH_PORT_SET" == false ]]; then
        detect_ssh_ports
    fi
    SSH_PORT_LIST="$(
        IFS=,
        echo "${SSH_PORTS[*]}"
    )"
    check_install_options

    printf 'Initializing Ubuntu: SSH=%s, Upgrade=%s, Fail2ban=%s, Docker=%s, Caddy=%s\n' \
        "$SSH_PORT_LIST" "$UPGRADE_SYSTEM" "$INSTALL_FAIL2BAN" "$INSTALL_DOCKER" "$INSTALL_CADDY"

    if [[ "$UPGRADE_SYSTEM" == true ]]; then
        upgrade_system
    fi
    install_base_packages
    configure_firewall

    if [[ "$INSTALL_FAIL2BAN" == true ]]; then
        install_fail2ban
    fi
    if [[ "$INSTALL_DOCKER" == true ]]; then
        install_docker
    fi
    if [[ "$INSTALL_CADDY" == true ]]; then
        install_caddy
    fi

    echo "Ubuntu initialization completed."
    if [[ "$REBOOT_REQUIRED" == true || -f /var/run/reboot-required ]]; then
        echo "A reboot is required to activate the new kernel/system. Run: sudo reboot"
    fi
}

trap cleanup EXIT
main "$@"
