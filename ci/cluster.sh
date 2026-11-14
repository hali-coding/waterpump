#!/bin/sh
# Form a cluster from a set's nodes, the first node starting it:
#
#   ci/cluster.sh ci
#
# The order is the one learned forming clusters by hand: the
# first invite creates the cluster and its certificate, so that node is
# restarted to serve it; codes are single-use, so one per joiner, each
# handed over in a file (a filter piped into `join` that dies would leave
# the node half in); each joiner restarts to serve its own; the first code,
# which nobody redeemed, is revoked.
#
# Then it sizes the nodes into the managed `large` and `small` groups, and
# turns on local logins everywhere, with one admin user to try them
# with: CI_LOGIN_USER (default tester) and a fresh random password, saved in
# the set's state dir as `login` (ci/.state/<set>/login on a workstation,
# mode 600) and never printed.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"

[ $# -ge 1 ] || usage
set=$1
st=$(state_dir "$set")
[ -f "$st/nodes" ] || die "set $set is not up (ci/up.sh $set)"

# /api/auth, not /api/status: it answers without a login, so the wait
# still works once auth is on.
restart() {
    on "$set" "$1" 'export XDG_RUNTIME_DIR=/run/user/$(id -u)
        systemctl --user restart waterpump.service
        i=0; until curl -skf -o /dev/null https://127.0.0.1:8099/api/auth; do
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

# The large and small groups, as a person would make them from the Cluster
# tab. Rerunnable: it rebuilds both from scratch. A node it could not
# measure lands in neither group and the command still succeeds, so that is
# checked here; with every node just seen ready, it means something is wrong.
group "size the nodes into large and small"
sizing=$(wp "$set" "$first_ip" cluster group auto --json </dev/null)
printf '%s' "$sizing" | json '"\n".join("%s: %s" % (n["node"], ", ".join(n["groups"]) if n["ok"]
    else "not sized, " + str(n["error"])) for n in d["nodes"])'
[ "$(printf '%s' "$sizing" | json 'all(n["ok"] for n in d["nodes"])')" = True ] ||
    die "some nodes could not be sized"
endgroup

# A login to test the UI with. Made on the first node and copied to the rest
# with `cluster sync --kind users` (reconciliation leaves users alone), so
# one password works on every node. The password reaches the node on stdin
# and the CLI through WATERPUMP_PASSWORD, never argv. Auth settings are per
# node and have no non-interactive `configure`, so they are written through
# auth.save_settings(), which validates them as `configure auth` would.
# Every node already serves TLS, which a password login requires. The CLI
# is unaffected: it calls its own serve with the cluster credential.
login_user=${CI_LOGIN_USER:-tester}
group "login $login_user on every node"
password=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)
# Sync with no --node is this node alone, so name every other one.
to=$(tail -n +2 "$st/nodes" | while read -r vmid name _; do printf ' --node %s' "$(q "$name")"; done)
printf '%s\n' "$password" | on "$set" "$first_ip" "u=$(q "$login_user"); set --$to"'
    cd ~/waterpump
    IFS= read -r WATERPUMP_PASSWORD; export WATERPUMP_PASSWORD
    if ./waterpump users --json | python3 -c "import json,sys
sys.exit(0 if any(u[\"name\"] == sys.argv[1] for u in json.load(sys.stdin)) else 1)" "$u"; then
        ./waterpump user-set "$u" --password --role admin
    else
        ./waterpump user-add "$u" --role admin
    fi
    [ $# -eq 0 ] || ./waterpump cluster sync --kind users --name "$u" "$@"'
(umask 077; printf 'url=https://%s:8099\nuser=%s\npassword=%s\n' "$first_ip" "$login_user" "$password" > "$st/login")
while read -r vmid name os octet _; do
    on "$set" "$CI_NET.$octet" 'cd ~/waterpump && python3 -c "import sys
sys.path.insert(0, \"src\")
from waterpump import auth
s = auth.load_settings() or {}
s[\"methods\"] = [\"local\"] + [m for m in s.get(\"methods\") or [] if m != \"local\"]
auth.save_settings(s)"' </dev/null
    restart "$CI_NET.$octet"
done < "$st/nodes"
log "UI login: $st/login"
endgroup
