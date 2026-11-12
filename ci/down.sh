#!/bin/sh
# Destroy every VM of a set (all its slots, whatever up.sh was asked for):
#
#   ci/down.sh ci
#
# Only VMs whose name matches nodes.conf are touched; a VMID holding
# anything else is refused rather than deleted.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"
. "$ci/lib/pve.sh"

set=${1:?usage: down.sh <set>}
[ -n "$(conf_nodes "$set")" ] || die "nodes.conf has no set $set"
st=$(state_dir "$set")

group "destroy $set"
# Stop every control master first, or their sockets outlive the VMs.
[ ! -f "$st/nodes" ] || while read -r _ _ _ octet _; do
    # shellcheck disable=SC2046
    ssh $(ssh_opts "$set") -O exit "ci@$CI_NET.$octet" </dev/null 2>/dev/null || true
done < "$st/nodes"
conf_nodes "$set" | while read -r vmid name _; do pve_destroy "$vmid" "$name"; done
rm -f "$st/nodes" "$st/known_hosts" "$st"/install-*.log "$st/waterpump.tar.gz"
endgroup
