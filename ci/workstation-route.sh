#!/bin/sh
# Route this workstation to the CI bridge through the Proxmox host, so the
# VMs and the API are reached directly (no jump host). Run by hand; it is
# never needed in CI, where the runner already sits on the bridge.
#
#   ci/workstation-route.sh            # add it now (until reboot)
#   ci/workstation-route.sh --persist  # ... and in NetworkManager, for good
#
# The host only forwards new connections from CI_TRUSTED_SRC, so add this
# machine's address there (ci/.env) and re-run ci/host/apply.sh first.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"
[ -n "${PVE_LAN_IP:-}" ] || die "PVE_LAN_IP is not set (ci/.env)"
net=$CI_NET.0/24

sudo ip route replace "$net" via "$PVE_LAN_IP"
log "route $net via $PVE_LAN_IP"

if [ "${1:-}" = --persist ]; then
    need nmcli
    dev=$(ip -4 route get "$PVE_LAN_IP" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    conn=$(nmcli -g GENERAL.CONNECTION device show "$dev")
    [ -n "$conn" ] || die "no NetworkManager connection on $dev; add the route in your network config instead"
    if nmcli -g ipv4.routes connection show "$conn" | grep -q "$net"; then
        log "already persistent in '$conn'"
    else
        sudo nmcli connection modify "$conn" +ipv4.routes "$net $PVE_LAN_IP"
        log "persisted in NetworkManager connection '$conn'"
    fi
fi
