#!/bin/bash

configure_package_manager() {
    export DEBIAN_FRONTEND=noninteractive
    export APT_LISTCHANGES_FRONTEND=none
    export UCF_FORCE_CONFFOLD=1
    # Report stale services; leave additional restarts to the final reboot decision.
    export NEEDRESTART_MODE=l
}

apt_get() {
    command apt-get \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}
