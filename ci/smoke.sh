#!/bin/sh
# Run the single-node smoke test (.github/scripts/daemon_smoke.sh) on one
# node of a set, against that node's own daemon, from the tree install.sh
# put there:
#
#   ci/smoke.sh ci             # on the set's first node
#   ci/smoke.sh dev dev-debian # on the node of that name
#
# cluster.yml runs it after the install and before the cluster is formed,
# so a fault in the everyday path on one host shows as that, not as a
# cluster test failing four ways at once. It needs no cluster: the smoke
# keeps its own data dir and serves on its own port, beside the node's
# service, so it also runs against a dev cluster that is already formed.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"

[ $# -ge 1 ] || usage
set=$1
st=$(state_dir "$set")
[ -f "$st/nodes" ] || die "set $set is not up (ci/up.sh $set)"

if [ $# -ge 2 ]; then
    row=$(awk -v n="$2" '$2 == n' "$st/nodes")
    [ -n "$row" ] || die "no node $2 in set $set"
else
    row=$(head -n 1 "$st/nodes")
fi
set -- $row
name=$2 ip=$CI_NET.$4 flavor=$5

# No group around it: the smoke prints its own, and Actions cannot nest them.
# The flavor is the node's, since the smoke defaults to Incus.
log "smoke test on $name ($flavor)"
on "$set" "$ip" "cd ~/waterpump && WATERPUMP_FLAVOR=$(q "$flavor") sh .github/scripts/daemon_smoke.sh" </dev/null
