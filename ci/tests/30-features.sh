# The experimental features (stacks, fabrics) are one cluster setting: a
# switch on one node reaches every member, a stack is refused while stacks
# are off, and stacks cannot be switched off while one exists. The cluster is
# left with the flags it started with, since a dev cluster is reused.
stack=ci-features

# flags <ip>: that node's stacks flag, on or off.
flags() {
    wp "$SET" "$1" features --json </dev/null |
        python3 -c 'import json,sys; print("on" if json.load(sys.stdin)["settings"]["stacks"] else "off")'
}
# everywhere <on|off>: every member agrees on the stacks flag.
everywhere() {
    while read -r _ name _ octet _; do
        got=$(flags "$CI_NET.$octet") || fail "features on $name"
        [ "$got" = "$1" ] || fail "$name has stacks $got, expected $1"
    done < "$NODES"
}

before=$(flags "$FIRST_IP")
in_use=$(wp "$SET" "$FIRST_IP" features --json </dev/null |
    python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["in_use"]["stacks"]))')
cleanup() {
    wp "$SET" "$FIRST_IP" stack-delete "$stack" -y </dev/null >/dev/null 2>&1 || true
    if [ "$before" = on ]; then
        wp "$SET" "$FIRST_IP" features-set --enable stacks </dev/null >/dev/null 2>&1 || true
    else
        wp "$SET" "$FIRST_IP" features-set --disable stacks </dev/null >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

nap='{"stages": [{"steps": [{"id": "nap", "type": "sleep", "seconds": 1}]}]}'

if [ -z "$in_use" ]; then
    wp "$SET" "$FIRST_IP" features-set --disable stacks </dev/null || fail "switch stacks off"
    everywhere off
    if printf '%s' "$nap" | wp "$SET" "$FIRST_IP" stack-save "$stack" - 2>/dev/null; then
        fail "a stack was saved while stacks are off"
    fi
else
    echo "stacks in use here ($in_use): the off half is skipped"
fi

# Switched on from another node than the first: the push goes both ways.
second_ip=$CI_NET.$(awk 'NR == 2 { print $4 }' "$NODES")
wp "$SET" "$second_ip" features-set --enable stacks </dev/null || fail "switch stacks on"
everywhere on
printf '%s' "$nap" | wp "$SET" "$FIRST_IP" stack-save "$stack" - || fail "stack-save with stacks on"

if wp "$SET" "$FIRST_IP" features-set --disable stacks </dev/null 2>/dev/null; then
    fail "stacks were switched off while a stack exists"
fi
everywhere on

wp "$SET" "$FIRST_IP" stack-delete "$stack" -y </dev/null || fail "stack-delete"
if [ -z "$in_use" ]; then
    wp "$SET" "$FIRST_IP" features-set --disable stacks </dev/null \
        || fail "switch stacks off once no stack exists"
    everywhere off
fi
echo "features: one setting for the cluster, refused while in use"
