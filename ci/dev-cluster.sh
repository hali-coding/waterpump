#!/bin/sh
# A cluster for trying things by hand, on the same templates and scripts CI
# uses, kept until you take it down:
#
#   ci/dev-cluster.sh up [--small]   four nodes (two with --small), this checkout installed
#   ci/dev-cluster.sh update         reinstall this checkout on every node, keep their state
#   ci/dev-cluster.sh status         VMs and cluster membership
#   ci/dev-cluster.sh ssh <n> [cmd] a shell on node n (1-based) as ci, or run cmd there
#   ci/dev-cluster.sh ui <n|name>    tunnel node n's UI to https://localhost:8099
#   ci/dev-cluster.sh test [filter]  run ci/tests against it
#   ci/dev-cluster.sh down           destroy it
#
# Needs ci/.env and the route to the CI bridge (ci/workstation-route.sh). It and
# a CI run never share the host: up refuses while a run holds it, and a run
# fails while this is up.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"
SET=dev

node_ip() {
    st=$(state_dir $SET)
    [ -f "$st/nodes" ] || die "the dev cluster is not up"
    case $1 in
        [0-9]*) octet=$(awk -v n="$1" 'NR == n { print $4 }' "$st/nodes") ;;
        *) octet=$(awk -v n="$1" '$2 == n { print $4 }' "$st/nodes") ;;
    esac
    [ -n "$octet" ] || die "no node $1"
    echo "$CI_NET.$octet"
}

# Build the UI when web/dist is missing or older than anything it is built
# from: a dev cluster runs this checkout, UI edits and branch switches
# included, and a stale bundle would quietly show the old UI.
web_fresh() {
    local d=$repo/web/dist/index.html
    if [ ! -f "$d" ] || [ -n "$(cd "$repo/web" && find src public index.html package.json \
            package-lock.json vite.config.* -newer "$d" -print 2>/dev/null | head -n 1)" ]; then
        log "building the UI (web/dist is missing or older than web/)"
        (cd "$repo" && ./build.sh)
    fi
}

cmd=${1:-status}
[ $# -eq 0 ] || shift
case $cmd in
    up)
        count=
        [ "${1:-}" = --small ] && count=2
        web_fresh
        "$ci/up.sh" $SET $count
        "$ci/install.sh" $SET
        "$ci/cluster.sh" $SET
        log "up. ssh: ci/dev-cluster.sh ssh 1   UI: ci/dev-cluster.sh ui 1"
        ;;
    update)
        web_fresh
        "$ci/install.sh" $SET
        ;;
    status)
        . "$ci/lib/pve.sh"
        pve_vms | jq -r '.[] | select(.name | startswith("dev-")) | "\(.vmid)  \(.name)  \(.status)"'
        st=$(state_dir $SET)
        [ -f "$st/nodes" ] && wp $SET "$(node_ip 1)" cluster status || true
        ;;
    ssh)
        ip=$(node_ip "${1:?which node}"); shift
        # With a command, run it there (`ssh 2 ./waterpump status`);
        # without one, a login shell in the checkout.
        # shellcheck disable=SC2046
        if [ $# -gt 0 ]; then
            exec ssh $(ssh_opts $SET) "ci@$ip" "cd ~/waterpump && $*"
        fi
        exec ssh $(ssh_opts $SET) -t "ci@$ip" 'cd ~/waterpump; exec $SHELL -l'
        ;;
    ui)
        ip=$(node_ip "${1:?which node}")
        port=${2:-8099}
        # The tunnel must end at the node's loopback: a cluster member
        # answers any other caller with a 401, even with auth off.
        log "https://localhost:$port -> $ip (Ctrl-C to close)"
        # shellcheck disable=SC2046
        exec ssh $(ssh_opts $SET) -N -o ControlMaster=no -L "$port:127.0.0.1:8099" "ci@$ip"
        ;;
    test)
        exec "$ci/tests/run.sh" $SET "${1:-}"
        ;;
    down)
        "$ci/down.sh" $SET
        ;;
    *)
        sed -n '4,11p' "$0" | sed 's/^# *//' >&2
        exit 2
        ;;
esac
