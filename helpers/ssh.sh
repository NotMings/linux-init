#!/bin/bash

restore_ssh_configuration() {
    local backup_dir="$1" file

    cp -a --remove-destination "$backup_dir/sshd_config" /etc/ssh/sshd_config || return 1
    for file in "$backup_dir"/dropins/*.conf; do
        [[ -f "$file" || -L "$file" ]] || continue
        cp -a --remove-destination "$file" "/etc/ssh/sshd_config.d/${file##*/}" || return 1
    done
    if [[ -f "$backup_dir/ssh.socket.conf" || -L "$backup_dir/ssh.socket.conf" ]]; then
        cp -a --remove-destination "$backup_dir/ssh.socket.conf" \
            /etc/systemd/system/ssh.socket.d/99-linux-init.conf || return 1
    else
        rm -f /etc/systemd/system/ssh.socket.d/99-linux-init.conf || return 1
    fi
}

write_ssh_ports() {
    local backup_dir="$1" file is_main

    for file in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$file" ]] || continue
        is_main=false
        [[ "$file" != /etc/ssh/sshd_config ]] || is_main=true
        awk -v ports="${SSH_PORTS[*]}" -v is_main="$is_main" '
            BEGIN {
                if (is_main == "true") {
                    print "# BEGIN linux-init SSH ports"
                    count = split(ports, values, " ")
                    for (i = 1; i <= count; i++) print "Port " values[i]
                    print "# END linux-init SSH ports"
                }
            }
            is_main == "true" && $0 == "# BEGIN linux-init SSH ports" { skip = 1; next }
            is_main == "true" && $0 == "# END linux-init SSH ports" { skip = 0; next }
            skip { next }
            {
                line = $0
                sub(/^[[:space:]]+/, "", line)
                split(line, fields, /[[:space:]=]+/)
                key = tolower(fields[1])
                if (key == "port") {
                    print "# linux-init disabled: " $0
                    next
                }
                if (key == "listenaddress") {
                    # Preserve interface bindings, applying all requested Port directives.
                    original = fields[2]
                    address = original
                    if (address ~ /^\[[^]]+\]:[0-9]+$/) {
                        sub(/^\[/, "", address)
                        sub(/\]:[0-9]+$/, "", address)
                    } else if (address ~ /^[^:]+:[0-9]+$/) {
                        sub(/:[0-9]+$/, "", address)
                    }
                    offset = index($0, original)
                    if (offset && address != original) {
                        $0 = substr($0, 1, offset - 1) address substr($0, offset + length(original))
                    }
                }
                print
            }
            END { if (skip) exit 1 }
        ' "$file" > "$backup_dir/updated" &&
            chmod --reference="$file" "$backup_dir/updated" &&
            chown --reference="$file" "$backup_dir/updated" &&
            mv -f -- "$backup_dir/updated" "$file" || return 1
    done
}

configure_ssh() {
    local sshd_bin backup_dir file config expected actual
    local socket_active=false socket_enabled=false

    sshd_bin="$(command -v sshd || true)"
    if [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]]; then
        sshd_bin=/usr/sbin/sshd
    fi
    [[ -n "$sshd_bin" ]] || die "OpenSSH server is required to configure --ssh ports."
    install -d -m 0755 /run/sshd
    "$sshd_bin" -t || die "Existing SSH configuration is invalid; no ports were changed."
    if systemctl is-active --quiet ssh.socket; then
        socket_active=true
    fi
    if systemctl is-enabled --quiet ssh.socket; then
        socket_enabled=true
    fi

    install -d -m 0700 /var/backups/linux-init
    backup_dir="$(mktemp -d /var/backups/linux-init/ssh-configuration.XXXXXX)"
    install -d -m 0700 "$backup_dir/dropins"
    cp -a /etc/ssh/sshd_config "$backup_dir/sshd_config"
    for file in /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "$file" || -L "$file" ]] || continue
        cp -a "$file" "$backup_dir/dropins/"
    done
    if [[ -e /etc/systemd/system/ssh.socket.d/99-linux-init.conf ||
        -L /etc/systemd/system/ssh.socket.d/99-linux-init.conf ]]; then
        cp -a /etc/systemd/system/ssh.socket.d/99-linux-init.conf "$backup_dir/ssh.socket.conf"
    fi
    echo "SSH configuration backup: $backup_dir"

    if ! write_ssh_ports "$backup_dir" || ! "$sshd_bin" -t || ! config="$("$sshd_bin" -T)"; then
        restore_ssh_configuration "$backup_dir"
        die "SSH configuration update failed and was restored from $backup_dir."
    fi
    expected="$(printf '%s\n' "${SSH_PORTS[@]}" | sort -un)"
    actual="$(awk '
        $1 == "port" { print $2 }
        $1 == "listenaddress" { address = $2; sub(/^.*:/, "", address); print address }
    ' <<< "$config" | sort -un)"
    if [[ "$actual" != "$expected" ]]; then
        restore_ssh_configuration "$backup_dir"
        die "Other SSH includes override the requested ports; configuration restored from $backup_dir."
    fi

    if [[ "$socket_active" == true || "$socket_enabled" == true ]]; then
        if ! install -d -m 0755 /etc/systemd/system/ssh.socket.d || ! {
            printf '[Socket]\nListenStream=\nBindIPv6Only=ipv6-only\n' &&
                awk '$1 == "listenaddress" { print "ListenStream=" $2 }' <<< "$config"
        } > /etc/systemd/system/ssh.socket.d/99-linux-init.conf; then
            restore_ssh_configuration "$backup_dir"
            die "Cannot configure ssh.socket; SSH configuration restored from $backup_dir."
        fi
    fi
    REBOOT_REQUIRED=true
    echo "SSH ports configured: $SSH_PORT_LIST. Changes take effect after reboot."
}
