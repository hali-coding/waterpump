# Tasks across the mixed cluster: one task on group `all` (every member, the
# group a single server has too) is run on each node in turn, and then on a
# one-minute schedule -- where the vote must give every occurrence to exactly
# one node, whatever OS or daemon each candidate runs.
tpl=ci-task
task=ci-task
image=${CI_TEST_IMAGE:-images:debian/13}

cleanup() {
    wp "$SET" "$FIRST_IP" task-delete "$task" -y </dev/null >/dev/null 2>&1 || true
    wp "$SET" "$FIRST_IP" template-delete "$tpl" -y </dev/null >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

wp "$SET" "$FIRST_IP" template-save "$tpl" --image "$image" \
    --description "ci/tests/20-tasks.sh" </dev/null || fail "template-save"
printf 'echo "ran on $(hostname)"\n' | wp "$SET" "$FIRST_IP" task-save "$task" -t "$tpl" \
    --script - --group all --no-schedule || fail "task-save on group all"

# On demand, on each member by name: every node can launch, run and destroy.
awk '{ print $2 }' "$NODES" > "$NODES.task"
while read -r node; do
    wp "$SET" "$FIRST_IP" task-run "$task" --node "$node" --json </dev/null | python3 -c '
import json, sys
run = json.load(sys.stdin)
assert run["status"] == "ok", "%s: %s %s" % (sys.argv[1], run["status"], run.get("error"))
assert run["node"] == sys.argv[1], "asked for %s, ran on %s" % (sys.argv[1], run["node"])
print("%s: ok" % sys.argv[1])' "$node" || fail "task-run on $node"
done < "$NODES.task"
rm -f "$NODES.task"

# Nothing left: every run's instance is destroyed when it ends.
wp "$SET" "$FIRST_IP" cluster containers --json </dev/null | python3 -c '
import json, sys
left = [(i["node"], i["name"]) for i in json.load(sys.stdin)["instances"]
        if i["name"].startswith("task-%s-" % sys.argv[1])]
assert not left, "left behind: %s" % left' "$task" || fail "task instances left behind"

# Scheduled: every minute for a few minutes, then each occurrence (slot) must
# have been run by one node only.
printf 'echo "ran on $(hostname)"\n' | wp "$SET" "$FIRST_IP" task-save "$task" -t "$tpl" \
    --script - --group all --cron '* * * * *' --tz UTC --enable || fail "task-save scheduled"
sleep 200
wp "$SET" "$FIRST_IP" task-disable "$task" </dev/null || fail "task-disable"
# A run still going finishes before it is counted.
sleep 30

wp "$SET" "$FIRST_IP" task-runs "$task" --limit 200 --json </dev/null | python3 -c '
import collections, json, sys
d = json.load(sys.stdin)
assert not d["errors"], "members did not answer: %s" % d["errors"]
ran = collections.defaultdict(list)
for run in d["runs"]:
    if run["trigger"] == "schedule" and run["status"] in ("running", "ok", "failed", "timed_out", "cancelled"):
        ran[run["slot"]].append((run["node"], run["status"]))
twice = {slot: runs for slot, runs in ran.items() if len(runs) > 1}
assert not twice, "an occurrence ran more than once: %s" % twice
ok = [slot for slot, runs in ran.items() if runs[0][1] == "ok"]
assert len(ok) >= 2, "expected at least two scheduled runs, got %s" % dict(ran)
print("%d occurrences, each run once, on %s" % (
    len(ran), ", ".join(sorted({r[0][0] for r in ran.values()}))))' || fail "at most once"
echo "tasks: on demand on every node, and scheduled runs voted to one node each"
