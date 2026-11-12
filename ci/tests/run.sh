#!/bin/sh
# Run every ci/tests/NN-*.sh against a set's cluster, in order:
#
#   ci/tests/run.sh ci                # all of them
#   ci/tests/run.sh dev 10-instance   # the ones whose name contains this
#
# A test is a sh script; it is sourced into a subshell that already has
# lib/common.sh and these, so a test reads like a list of steps:
#   $SET             the set name, for on/wp
#   $NODES           the set's node list file (vmid name os octet flavor ...)
#   $FIRST_IP        the node the cluster was started on
#   ip_of <name>     a node's address
#   fail <message>   fail this test
# Each runs in a subshell, so one failing does not stop the rest; the
# runner fails at the end if any did.
set -eu
ci=$(cd "$(dirname "$0")/.." && pwd)
. "$ci/lib/common.sh"

[ $# -ge 1 ] || usage
SET=$1
filter=${2:-}
NODES=$(state_dir "$SET")/nodes
[ -f "$NODES" ] || die "set $SET is not up"
FIRST_IP=$CI_NET.$(awk 'NR == 1 { print $4 }' "$NODES")
export SET NODES FIRST_IP

ip_of() { awk -v n="$1" -v net="$CI_NET" '$2 == n { print net "." $4 }' "$NODES"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

failed='' passed=0
for t in "$ci"/tests/[0-9]*.sh; do
    name=$(basename "$t" .sh)
    case $name in *"$filter"*) ;; *) continue ;; esac
    group "test $name"
    # Not as an `if` condition: errexit is off inside one, subshells
    # included, and a test should stop at its first failing step.
    set +e
    ( set -eu; . "$t" ) </dev/null
    rc=$?
    set -e
    if [ "$rc" = 0 ]; then
        passed=$((passed + 1)); echo "ok: $name"
    else
        failed="$failed $name"
        [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=$name::test failed"
    fi
    endgroup
done
echo "$passed passed${failed:+, failed:$failed}"
[ -z "$failed" ]
