#!/bin/sh
# Bring up a set's VMs from the newest templates:
#
#   ci/up.sh ci            # the four CI nodes (cluster.yml)
#   ci/up.sh dev [2]       # the dev cluster, or only its first two nodes
#
# Whatever is left in the set's slots from an earlier run is destroyed
# first, so a run that died halfway heals on the next one. The other set
# must not be up: 16 GB holds one set, not two.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"
. "$ci/lib/pve.sh"
need ssh ssh-keygen

set=${1:?usage: up.sh <set> [count]}
count=${2:-}
case $set in ci) other=dev ;; dev) other=ci ;; *) die "unknown set $set (ci or dev)" ;; esac
[ -n "$(conf_nodes "$set")" ] || die "nodes.conf has no set $set"

vms=$(pve_vms)
busy=$(conf_nodes "$other" | while read -r vmid name _; do
    printf '%s' "$vms" | jq -r --argjson id "$vmid" --arg n "$name" \
        '.[] | select(.vmid == $id and .name == $n) | .name'
done)
if [ -n "$busy" ]; then
    case $other in
        dev) die "the dev cluster is up ($(echo $busy)); bring it down first: ci/dev-cluster.sh down" ;;
        *) die "a CI run holds the host ($(echo $busy)); wait for it, or ci/down.sh ci if it is stale" ;;
    esac
fi

st=$(state_dir "$set")
rm -f "$st/known_hosts"
[ -f "$st/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C "wpci-$set" -f "$st/id_ed25519"
keys=$st/authorized_keys
cat "$st/id_ed25519.pub" > "$keys"
# A dev cluster is for people: let the workstation's own keys in as well,
# so plain `ssh ci@<ip>` works.
[ "$set" = ci ] || cat ~/.ssh/id_*.pub >> "$keys" 2>/dev/null || true

if [ -n "$count" ]; then conf_nodes "$set" | head -n "$count"; else conf_nodes "$set"; fi > "$st/nodes.new"
# Every slot of the set is cleared, not just the ones about to be used.
conf_nodes "$set" | while read -r vmid name _; do pve_destroy "$vmid" "$name"; done
mv "$st/nodes.new" "$st/nodes"

tag=$set
[ -n "${GITHUB_RUN_ID:-}" ] && tag="$tag;run-$GITHUB_RUN_ID"

group "clone"
while read -r vmid name os octet flavor cores mem balloon disk; do
    tpl=$(pve_template_for "$os")
    [ -n "$tpl" ] || die "no template for $os: run ci/build-templates.sh $os"
    log "$name ($vmid) from $(pve_name_of "$tpl"), $flavor, $CI_NET.$octet"
    pve_task "$(pve POST "$(qm_path "$tpl")/clone" --data-urlencode "newid=$vmid" \
        --data-urlencode "name=$name" --data-urlencode "pool=$CI_POOL" --data-urlencode full=0)"
    pve PUT "$(qm_path "$vmid")/config" \
        --data-urlencode "cores=$cores" --data-urlencode "memory=$mem" \
        --data-urlencode "balloon=$balloon" \
        --data-urlencode "ipconfig0=ip=$CI_NET.$octet/24,gw=$CI_GW" \
        --data-urlencode "nameserver=$CI_DNS" --data-urlencode ciuser=ci \
        --data-urlencode "sshkeys=$(pve_sshkeys "$keys")" \
        --data-urlencode "tags=wpci;$tag;$os;$flavor" >/dev/null
    pve PUT "$(qm_path "$vmid")/resize" --data-urlencode disk=scsi0 \
        --data-urlencode "size=${disk}G" >/dev/null
    pve_task "$(pve POST "$(qm_path "$vmid")/status/start")"
done < "$st/nodes"
endgroup

group "wait for ssh"
while read -r vmid name os octet _; do
    wait_ssh "$set" "$CI_NET.$octet" 60
    log "$name: $(on "$set" "$CI_NET.$octet" '. /etc/os-release; echo "$PRETTY_NAME"' </dev/null)"
done < "$st/nodes"
endgroup
