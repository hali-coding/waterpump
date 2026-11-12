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

[ $# -ge 1 ] || usage
set=$1
[ -n "$(conf_nodes "$set")" ] || die "nodes.conf has no set $set"
st=$(state_dir "$set")

group "destroy $set"
# Stop every control master first, or their sockets outlive the VMs.
[ ! -f "$st/nodes" ] || while read -r _ _ _ octet _; do
    # shellcheck disable=SC2046
    ssh $(ssh_opts "$set") -O exit "ci@$CI_NET.$octet" </dev/null 2>/dev/null || true
done < "$st/nodes"
conf_nodes "$set" | while read -r vmid name _; do pve_destroy "$vmid" "$name"; done
# Last, once the VMs are gone: the hold is what keeps the other set out.
pve_release "$set"
# The whole state dir, key and login included: the next up.sh makes a new
# key, and nothing outlives the VMs it was for.
rm -rf "$st"
rmdir "${st%/*}" 2>/dev/null || true
endgroup
