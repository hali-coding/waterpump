# Every node is up, runs the daemon nodes.conf says it does, and sees the
# whole cluster -- the floor every later test stands on.
while read -r vmid name os octet flavor _; do
    ip=$CI_NET.$octet
    status=$(wp "$SET" "$ip" status --json)
    printf '%s' "$status" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want = sys.argv[1]
assert d["ready"], "%s: daemon not ready: %r" % (sys.argv[2], d)
got = (d.get("flavor") or d.get("product") or "").lower()
assert want in got, "%s: expected %s, got %r" % (sys.argv[2], want, got)
print("%s: %s ready" % (sys.argv[2], got))' "$flavor" "$name" || fail "$name status"
done < "$NODES"

want=$(wc -l < "$NODES")
wp "$SET" "$FIRST_IP" cluster status --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
names = sorted(n["name"] for n in d["nodes"])
assert len(names) == int(sys.argv[1]), names
bad = [n["name"] for n in d["nodes"] if not n["self"] and not (n["state"] or {}).get("reachable")]
assert not bad, "unreachable: %s" % bad
print("members:", ", ".join(names))' "$want" || fail "membership"
