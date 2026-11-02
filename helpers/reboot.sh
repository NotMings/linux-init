#!/bin/bash

prompt_reboot() {
    local answer

    if [[ "$REBOOT_REQUIRED" == true || -f /var/run/reboot-required ]]; then
        echo "A reboot is required to apply the pending SSH/system changes."
    fi
    # Do not consume piped commands or block non-interactive callers such as CI.
    if [[ ! -t 0 ]]; then
        echo "Non-interactive session; reboot skipped. Run: sudo reboot"
        return 0
    fi

    read -r -p "Reboot now? [y/N] " answer || answer=""
    case "${answer,,}" in
        y | yes) systemctl reboot ;;
        *) echo "Reboot skipped. Run: sudo reboot" ;;
    esac
}
