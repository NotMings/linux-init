#!/bin/bash

set -euo pipefail

: "${VM_DIR:?VM_DIR must point to the disposable GitHub Actions VM directory}"
SSH_OPTIONS=(-i "$VM_DIR/id_ed25519" -o BatchMode=yes -o StrictHostKeyChecking=accept-new
    -o "UserKnownHostsFile=$VM_DIR/known_hosts" -o ConnectTimeout=3
    -o ServerAliveInterval=15 -o ServerAliveCountMax=8)

guest_ssh() {
    ssh "${SSH_OPTIONS[@]}" -p 2222 debian@127.0.0.1 "$@"
}

wait_for_ssh() {
    local previous_boot="${1:-}" boot deadline=$((SECONDS + 600))
    while (( SECONDS < deadline )); do
        if boot="$(guest_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null)"; then
            if [[ -n "$boot" && "$boot" != "$previous_boot" ]]; then
                guest_ssh sudo cloud-init status --wait
                return 0
            fi
        fi
        sleep 3
    done
    echo "Timed out waiting for Debian SSH/cloud-init." >&2
    tail -n 100 "$VM_DIR/logs/serial.log" >&2 || true
    return 1
}

case "${1:-}" in
    start)
        : "${DEBIAN_VERSION:?Missing Debian version}"
        : "${DEBIAN_CODENAME:?Missing Debian codename}"
        [[ "$DEBIAN_VERSION" =~ ^[0-9]+$ && "$DEBIAN_CODENAME" =~ ^[a-z][a-z0-9]*$ ]]
        mkdir -p "$VM_DIR/logs"
        # QEMU runs as root; keep the serial log owned by the Actions runner.
        install -m 0600 /dev/null "$VM_DIR/logs/serial.log"
        ssh-keygen -q -t ed25519 -N '' -f "$VM_DIR/id_ed25519"
        public_key="$(cat "$VM_DIR/id_ed25519.pub")"
        curl --fail --show-error --location --retry 3 --max-time 600 \
            "https://cloud.debian.org/images/cloud/$DEBIAN_CODENAME/latest/debian-$DEBIAN_VERSION-genericcloud-amd64.qcow2" \
            --output "$VM_DIR/disk.qcow2"
        qemu-img resize "$VM_DIR/disk.qcow2" 16G
        cat > "$VM_DIR/user-data" <<EOF
#cloud-config
hostname: linux-init-ci
users:
  - name: debian
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
runcmd:
  - [bash, -c, 'systemctl disable --now ssh.socket 2>/dev/null || true; systemctl enable ssh; systemctl restart ssh']
EOF
        printf 'instance-id: linux-init-ci\nlocal-hostname: linux-init-ci\n' > "$VM_DIR/meta-data"
        cloud-localds "$VM_DIR/seed.img" "$VM_DIR/user-data" "$VM_DIR/meta-data"
        if [[ -e /dev/kvm ]]; then
            accelerator=(-accel kvm -cpu host)
        else
            accelerator=(-accel tcg,thread=multi -cpu max)
        fi
        sudo qemu-system-x86_64 "${accelerator[@]}" -m 3072 -smp 2 \
            -drive "file=$VM_DIR/disk.qcow2,if=virtio,format=qcow2" \
            -drive "file=$VM_DIR/seed.img,if=virtio,format=raw,readonly=on" \
            -netdev user,id=network,hostfwd=tcp:127.0.0.1:2222-:2222,hostfwd=tcp:127.0.0.1:2200-:2200 \
            -device virtio-net-pci,netdev=network -display none \
            -serial "file:$VM_DIR/logs/serial.log" -daemonize -pidfile "$VM_DIR/qemu.pid"
        wait_for_ssh
        ;;
    copy)
        tar -czf "$VM_DIR/source.tar.gz" debian
        scp "${SSH_OPTIONS[@]}" -P 2222 "$VM_DIR/source.tar.gz" debian@127.0.0.1:/tmp/linux-init-source.tar.gz
        guest_ssh 'sudo mkdir -p /opt/linux-init && sudo tar -xzf /tmp/linux-init-source.tar.gz -C /opt/linux-init'
        ;;
    exec)
        shift
        guest_ssh "$@"
        ;;
    exec-secondary)
        shift
        ssh "${SSH_OPTIONS[@]}" -p 2200 debian@127.0.0.1 "$@"
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
            guest_ssh 'sudo journalctl --no-pager -b; sudo systemctl --failed --no-pager; sudo cat /var/log/apt/term.log' \
                > "$VM_DIR/logs/guest.log" 2>&1 || true
        fi
        ;;
    stop)
        if [[ -f "$VM_DIR/qemu.pid" ]]; then
            sudo kill "$(sudo cat "$VM_DIR/qemu.pid")" || true
        fi
        ;;
    *)
        echo "Usage: $0 {start|copy|exec|exec-secondary|reboot|logs|stop}" >&2
        exit 1
        ;;
esac
