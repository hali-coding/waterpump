# Instances, on every node: one template launched over group `all` puts an
# instance on each member -- every OS and both daemons -- and each one has to
# come up healthy, run a command, stop, start and be destroyed. This is
# waterpump's everyday path, so it is the one that must hold on every host.
#
# Uses images:debian/13: both daemons' `images:` remotes carry it.
tpl=ci-inst
image=${CI_TEST_IMAGE:-images:debian/13}
count=$(wc -l < "$NODES")

cleanup() {
    wp "$SET" "$FIRST_IP" template-destroy "$tpl" -y </dev/null >/dev/null 2>&1 || true
    wp "$SET" "$FIRST_IP" template-delete "$tpl" -y </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

wp "$SET" "$FIRST_IP" template-save "$tpl" --image "$image" \
    --description "ci/tests/10-instances.sh" </dev/null || fail "template-save"
# --no-serve: held by this command, so it returns when every share has.
wp "$SET" "$FIRST_IP" launch "$tpl" -n "$count" --group all --no-serve </dev/null \
    || fail "launch over group all"

# members: the template's instances as JSON, each with its health. A CLI
# process has no health rounds of its own -- serve keeps them -- so the node
# asked reports its own instances unjudged; asking a second node as well
# fills those in from that node's call to the first one's serve.
second_ip=$CI_NET.$(awk 'NR == 2 { print $4 }' "$NODES")
members() {
    FIRST=$(wp "$SET" "$FIRST_IP" cluster containers --json </dev/null) || return 1
    SECOND=$(wp "$SET" "$second_ip" cluster containers --json </dev/null) || return 1
    FIRST=$FIRST SECOND=$SECOND python3 -c '
import json, os, sys
first, second = json.loads(os.environ["FIRST"]), json.loads(os.environ["SECOND"])
health = {}
for d in (second, first):
    health.update({(h["node"], h["name"]): h["status"] for h in d.get("health") or []})
mine = [i for i in first["instances"] if i.get("template") == sys.argv[1]]
for i in mine:
    i["health"] = health.get((i["node"], i["name"]))
print(json.dumps(mine))' "$tpl"
}

members | python3 -c '
import json, sys
mine = json.load(sys.stdin)
nodes = sorted({i["node"] for i in mine})
want = int(sys.argv[1])
assert len(mine) == want, "expected %d instances, got %d" % (want, len(mine))
assert len(nodes) == want, "expected one per node, got %s" % nodes
assert all(i["status"] == "Running" for i in mine), [(i["name"], i["status"]) for i in mine]
print("running on", ", ".join(nodes))' "$count" || fail "one running instance per node"

# Each node judges health itself, on its own round, after a start grace: wait
# for every one to say healthy rather than assume a timing.
tries=0
until members | python3 -c '
import json, sys
mine = json.load(sys.stdin)
waiting = [(i["node"], i["health"]) for i in mine if i["health"] != "healthy"]
if waiting:
    print("waiting:", waiting)
    sys.exit(1)'; do
    tries=$((tries + 1))
    [ "$tries" -lt 40 ] || fail "not every instance became healthy"
    sleep 15
done

wp "$SET" "$FIRST_IP" template-exec --json "$tpl" -- sh -c 'cat /etc/os-release >/dev/null && echo ok' \
    </dev/null | python3 -c '
import json, sys
r = json.load(sys.stdin)
bad = [(i["name"], i.get("error") or (i.get("exec") or {}).get("exit_code"))
       for i in r["instances"]
       if i.get("error") or (i.get("exec") or {}).get("stdout", "").strip() != "ok"]
assert r["ok"] and not bad, bad
print("exec ok on", len(r["instances"]))' || fail "exec in every instance"

# Stop and start each on its own node: that node's daemon, nobody else's.
members | python3 -c '
import json, sys
for i in json.load(sys.stdin):
    print(i["node"], i["name"])' > "$NODES.inst"
while read -r node name; do
    ip=$(ip_of "$node")
    wp "$SET" "$ip" stop "$name" </dev/null || fail "stop $name on $node"
    wp "$SET" "$ip" start "$name" </dev/null || fail "start $name on $node"
done < "$NODES.inst"
rm -f "$NODES.inst"

members | python3 -c '
import json, sys
mine = json.load(sys.stdin)
assert all(i["status"] == "Running" for i in mine), [(i["name"], i["status"]) for i in mine]
' || fail "running again after stop and start"

wp "$SET" "$FIRST_IP" template-destroy "$tpl" -y </dev/null || fail "template-destroy"
members | python3 -c '
import json, sys
left = json.load(sys.stdin)
assert not left, "left behind: %s" % [(i["node"], i["name"]) for i in left]
' || fail "instances left after destroy"
echo "instances: launch, health, exec, stop/start and destroy on $count nodes"
