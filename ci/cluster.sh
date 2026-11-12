#!/bin/sh
# Form a cluster from a set's nodes, the first node starting it:
#
#   ci/cluster.sh ci
#
# The order is the one the build-testcluster skill learned by hand: the
# first invite creates the cluster and its certificate, so that node is
# restarted to serve it; codes are single-use, so one per joiner, each
# handed over in a file (a filter piped into `join` that dies would leave
# the node half in); each joiner restarts to serve its own; the first code,
# which nobody redeemed, is revoked.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"

set=${1:?usage: cluster.sh <set>}
st=$(state_dir "$set")
[ -f "$st/nodes" ] || die "set $set is not up (ci/up.sh $set)"

restart() {
    on "$set" "$1" 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
        systemctl --user restart waterpump.service
        i=0; until curl -skf -o /dev/null https://127.0.0.1:8099/api/status; do
            i=$((i+1)); [ $i -lt 60 ] || { journalctl --user -u waterpump -n 30 --no-pager; exit 1; }
            sleep 1; done' </dev/null
}
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

first=$(head -n 1 "$st/nodes")
set -- $first
first_name=$2 first_ip=$CI_NET.$4

group "start the cluster on $first_name"
starter=$(wp "$set" "$first_ip" cluster invite --json --note "ci: cluster start" </dev/null)
starter_id=$(printf '%s' "$starter" | json 'd["id"]')
restart "$first_ip"
endgroup

tail -n +2 "$st/nodes" | while read -r vmid name os octet flavor _; do
    ip=$CI_NET.$octet
    group "join $name"
    code=$(wp "$set" "$first_ip" cluster invite --json --note "ci: $name" </dev/null | json 'd["code"]')
    printf '%s\n' "$code" | on "$set" "$ip" 'umask 077; cat > ~/.join-code'
    on "$set" "$ip" 'cd ~/waterpump && ./waterpump cluster join - < ~/.join-code; rc=$?; rm -f ~/.join-code; exit $rc' </dev/null
    restart "$ip"
    endgroup
done

wp "$set" "$first_ip" cluster revoke-invite "$starter_id" </dev/null >/dev/null 2>&1 || true

# Membership converges through sync, so give every node a moment to see
# every other one before calling the cluster formed.
group "check membership"
want=$(wc -l < "$st/nodes")
i=0
while :; do
    ok=yes
    while read -r vmid name os octet _; do
        n=$(wp "$set" "$CI_NET.$octet" cluster status --json </dev/null | json \
            'sum(1 for n in d["nodes"] if n["self"] or (n["state"] or {}).get("reachable") and n["state"].get("ready"))')
        [ "$n" = "$want" ] || { ok=; log "$name sees $n of $want nodes ready"; }
    done < "$st/nodes"
    [ -z "$ok" ] || break
    i=$((i + 1)); [ "$i" -lt 12 ] || die "the cluster did not converge"
    sleep 10
done
wp "$set" "$first_ip" cluster status </dev/null
endgroup
