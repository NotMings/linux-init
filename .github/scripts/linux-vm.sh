#!/bin/bash

set -euo pipefail

: "${VM_DIR:?VM_DIR must point to the disposable GitHub Actions VM directory}"
VM_DISTRO="${VM_DISTRO:?VM_DISTRO must be debian or ubuntu}"
case "$VM_DISTRO" in
    debian | ubuntu) ;;
    *) echo "Unsupported VM distribution: $VM_DISTRO" >&2; exit 1 ;;
esac

SSH_OPTIONS=(-i "$VM_DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$VM_DIR/known_hosts" -o ConnectTimeout=3
    -o ServerAliveInterval=15 -o ServerAliveCountMax=8)

guest_ssh() {
    ssh "${SSH_OPTIONS[@]}" -p 2222 "$VM_DISTRO@127.0.0.1" "$@"
}

wait_for_ssh() {
    local previous_boot="${1:-}" boot status remaining deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        if boot="$(guest_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null)"; then
            if [[ -n "$boot" && "$boot" != "$previous_boot" ]]; then
                remaining=$((deadline - SECONDS))
                (( remaining > 0 )) || break
                if guest_ssh sudo timeout "$remaining" cloud-init status --wait; then
                    return 0
                else
                    status=$?
                fi
                # cloud-init may switch SSH listeners after the first successful probe.
                if [[ "$status" -ne 255 ]]; then
                    echo "cloud-init readiness check failed (exit $status)." >&2
                    tail -n 100 "$VM_DIR/logs/serial.log" >&2 || true
                    return "$status"
                fi
                echo "SSH connection interrupted during cloud-init; retrying..." >&2
            fi
        fi
        sleep 3
    done
    echo "Timed out waiting for $VM_DISTRO SSH/cloud-init." >&2
    tail -n 100 "$VM_DIR/logs/serial.log" >&2 || true
    return 1
}

case "${1:-}" in
    start)
        : "${OS_VERSION:?Missing OS version}"
        : "${OS_CODENAME:?Missing OS codename}"
        [[ "$OS_VERSION" =~ ^[0-9]+(\.[0-9]+)?$ && "$OS_CODENAME" =~ ^[a-z][a-z0-9]*$ ]]
        mkdir -p "$VM_DIR/logs"
        # QEMU runs as root; keep the serial log owned by the Actions runner.
        install -m 0600 /dev/null "$VM_DIR/logs/serial.log"
        ssh-keygen -q -t ed25519 -N '' -f "$VM_DIR/id_ed25519"
        public_key="$(cat "$VM_DIR/id_ed25519.pub")"
        firmware_args=()
        case "$VM_DISTRO" in
            debian)
                image_url="https://cloud.debian.org/images/cloud/$OS_CODENAME/latest/debian-$OS_VERSION-genericcloud-amd64.qcow2"
                ;;
            ubuntu)
                image_url="https://cloud-images.ubuntu.com/$OS_CODENAME/current/$OS_CODENAME-server-cloudimg-amd64.img"
                cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VM_DIR/OVMF_VARS.fd"
                firmware_args=(
                    -machine q35
                    -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd
                    -drive "if=pflash,format=raw,file=$VM_DIR/OVMF_VARS.fd"
                )
                ;;
        esac
        curl --fail --show-error --location --retry 3 --max-time 600 \
            "$image_url" --output "$VM_DIR/disk.qcow2"
        qemu-img resize "$VM_DIR/disk.qcow2" 16G
        cat > "$VM_DIR/user-data" <<EOF
#cloud-config
hostname: linux-init-ci
users:
  - name: $VM_DISTRO
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
package_update: false
package_upgrade: false
apt:
  preserve_sources_list: true
write_files:
  - path: /etc/ssh/sshd_config.d/99-ci-ports.conf
    content: |
      Port 2222
      Port 2200
  - path: /etc/apt/apt.conf.d/99-ci-noninteractive
    content: |
      Dpkg::Options {
        "--force-confdef";
        "--force-confold";
      };
  - path: /etc/systemd/system/ssh.socket.d/00-ci-ports.conf
    content: |
      [Socket]
      ListenStream=
      ListenStream=0.0.0.0:2222
      ListenStream=[::]:2222
      ListenStream=0.0.0.0:2200
      ListenStream=[::]:2200
      BindIPv6Only=ipv6-only
runcmd:
  - |
    set -e
    systemctl daemon-reload
    if [ "$VM_DISTRO" = ubuntu ] && systemctl cat ssh.socket >/dev/null 2>&1; then
        systemctl stop ssh.service ssh.socket
        systemctl disable ssh.service
        systemctl enable ssh.socket
        systemctl start ssh.socket || {
            systemctl status --no-pager --full ssh.socket ssh.service || true
            journalctl --no-pager -b -u ssh.socket -u ssh.service -n 100 || true
            exit 1
        }
    else
        systemctl disable --now ssh.socket 2>/dev/null || true
        systemctl enable ssh
        systemctl restart ssh
    fi
EOF
        printf 'instance-id: linux-init-ci\nlocal-hostname: linux-init-ci\n' > "$VM_DIR/meta-data"
        cloud-localds "$VM_DIR/seed.img" "$VM_DIR/user-data" "$VM_DIR/meta-data"
        if [[ -e /dev/kvm ]]; then
            accelerator=(-accel kvm -cpu host)
        else
            accelerator=(-accel tcg,thread=multi -cpu max)
        fi
        sudo qemu-system-x86_64 "${accelerator[@]}" "${firmware_args[@]}" -m 3072 -smp 2 \
            -drive "file=$VM_DIR/disk.qcow2,if=virtio,format=qcow2" \
            -drive "file=$VM_DIR/seed.img,if=virtio,format=raw,readonly=on" \
            -netdev user,id=network,hostfwd=tcp:127.0.0.1:2222-:2222,hostfwd=tcp:127.0.0.1:2200-:2200,hostfwd=tcp:127.0.0.1:52113-:52113 \
            -device virtio-net-pci,netdev=network -display none \
            -serial "file:$VM_DIR/logs/serial.log" -daemonize -pidfile "$VM_DIR/qemu.pid"
        wait_for_ssh
        ;;
    copy)
        tar -czf "$VM_DIR/source.tar.gz" "$VM_DISTRO" config_files helpers
        scp "${SSH_OPTIONS[@]}" -P 2222 "$VM_DIR/source.tar.gz" "$VM_DISTRO@127.0.0.1":/tmp/linux-init-source.tar.gz
        guest_ssh 'sudo mkdir -p /opt/linux-init && sudo tar -xzf /tmp/linux-init-source.tar.gz -C /opt/linux-init'
        ;;
    exec)
        shift
        guest_ssh "$@"
        ;;
    exec-secondary)
        shift
        ssh "${SSH_OPTIONS[@]}" -p 2200 "$VM_DISTRO@127.0.0.1" "$@"
        ;;
    exec-port)
        [[ $# -ge 3 && "$2" =~ ^[0-9]{1,5}$ ]]
        port=$((10#$2))
        (( port >= 1 && port <= 65535 ))
        shift 2
        ssh "${SSH_OPTIONS[@]}" -p "$port" "$VM_DISTRO@127.0.0.1" "$@"
        ;;
    reboot)
        previous_boot="$(guest_ssh cat /proc/sys/kernel/random/boot_id)"
        status=0
        guest_ssh sudo systemctl reboot || status=$?
        [[ "$status" -eq 0 || "$status" -eq 255 ]]
        wait_for_ssh "$previous_boot"
        ;;
    logs)
        mkdir -p "$VM_DIR/logs"
        # Also handle logs created by QEMU before a startup failure.
        if [[ -f "$VM_DIR/logs/serial.log" ]]; then
            sudo chown -- "$(id -u):$(id -g)" "$VM_DIR/logs/serial.log"
            chmod 0600 "$VM_DIR/logs/serial.log"
        fi
        if [[ -f "$VM_DIR/id_ed25519" ]]; then
            guest_ssh '
                sudo ss -ltnp
                sudo /usr/sbin/sshd -T
                sudo systemctl status --no-pager --full ssh.service ssh.socket
                sudo systemctl cat ssh.service ssh.socket
                sudo journalctl --no-pager -b
                sudo systemctl --failed --no-pager
                sudo cat /var/log/apt/term.log
            ' > "$VM_DIR/logs/guest.log" 2>&1 || true
        fi
        ;;
    stop)
        if [[ -f "$VM_DIR/qemu.pid" ]]; then
            sudo kill "$(sudo cat "$VM_DIR/qemu.pid")" || true
        fi
        ;;
    *)
        echo "Usage: $0 {start|copy|exec|exec-secondary|exec-port|reboot|logs|stop}" >&2
        exit 1
        ;;
esac
