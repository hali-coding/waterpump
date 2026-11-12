#!/bin/sh
# Gather what explains a failure from every node of a set into a directory
# (cluster.yml uploads it as an artifact):
#
#   ci/collect.sh ci /tmp/logs
#
# Best effort throughout: a node that is down is exactly when this runs.
set -u
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"

set=${1:?usage: collect.sh <set> <dir>}
out=${2:?usage: collect.sh <set> <dir>}
st=$(state_dir "$set")
mkdir -p "$out"
[ -f "$st/nodes" ] || { echo "set $set was never up" > "$out/README"; exit 0; }
cp "$st/nodes" "$st"/install-*.log "$out/" 2>/dev/null

while read -r vmid name os octet flavor _; do
    on "$set" "$CI_NET.$octet" 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
        cd ~/waterpump 2>/dev/null || exit 0
        echo "## os";            cat /etc/os-release
        echo "## status";        ./waterpump status 2>&1
        echo "## cluster";       ./waterpump cluster status 2>&1
        echo "## list";          ./waterpump list 2>&1
        echo "## memory";        free -m; swapon --show 2>&1
        echo "## cloud-init";    cloud-init status --long 2>&1
        echo "## service";       systemctl --user status waterpump --no-pager 2>&1
        echo "## journal";       journalctl --user -u waterpump -n 2000 --no-pager 2>&1
        echo "## dmesg";         sudo dmesg 2>&1 | tail -n 200' \
        </dev/null > "$out/$name.log" 2>&1 || echo "(unreachable)" >> "$out/$name.log"
done < "$st/nodes"
echo "logs in $out"
