#!/bin/sh
# A scheduled task to watch, on a formed set (after ci/cluster.sh):
#
#   ci/task-setup.sh dev
#
# Pins the newest build of DEBIAN_IMAGE (default images:debian/13, the
# current stable; debian/14 on the remotes is testing) as
# pin:golden-task-image, saves a template `golden-task` that launches it,
# and a task `test-task` on every node group that runs `echo "dog"` every five
# minutes. Rerunnable: a pin that already answers to the nickname is kept,
# and the template and task are saved over.
#
# Watch it with `./waterpump task-runs test-task` on any node, or the Tasks tab.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"

[ $# -ge 1 ] || usage
set=$1
st=$(state_dir "$set")
[ -f "$st/nodes" ] || die "set $set is not up (ci/up.sh $set)"

image=${DEBIAN_IMAGE:-images:debian/13}
nickname=golden-task-image
template=golden-task
task=test-task

json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
first_ip=$CI_NET.$(awk 'NR == 1 { print $4 }' "$st/nodes")

# A nickname names one pin cluster-wide, so a rerun cannot pin a newer build
# under it; keeping the existing one is what makes this rerunnable.
group "pin $image as pin:$nickname"
pinned=$(wp "$set" "$first_ip" image-pins --json </dev/null |
    json "next((p['name'] for p in d if '$nickname' in (p.get('nicknames') or [])), '')")
if [ -n "$pinned" ]; then
    log "already pinned: $pinned"
else
    # Fetched here and sent to every other node, so it takes a while.
    wp "$set" "$first_ip" image-pin "$image" --nickname "$nickname" \
        --note "ci/task-setup.sh: the image test-task runs on" </dev/null
fi
endgroup

group "template $template"
wp "$set" "$first_ip" template-save "$template" --image "pin:$nickname" \
    --description "ci/task-setup.sh: plain $image for tasks" </dev/null
endgroup

# A task must name groups, never "anywhere": every group the cluster has --
# large and small from cluster.sh's sizing -- is as close as it gets.
group "task $task"
groups=$(wp "$set" "$first_ip" cluster groups --json </dev/null |
    json "' '.join('--group ' + g['name'] for g in d)")
[ -n "$groups" ] || die "the cluster has no node groups (ci/cluster.sh sizes them)"
# shellcheck disable=SC2086
printf 'echo "dog"\n' | wp "$set" "$first_ip" task-save "$task" -t "$template" \
    --script - --cron '*/5 * * * *' $groups --enable
endgroup
