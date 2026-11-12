# Sourced by every ci/ script after it sets $ci to the ci/ directory.
# POSIX sh plus `local`: the controller is Debian (dash), a workstation may
# be anything, and every /bin/sh we meet -- dash, bash, busybox -- has it.

# ci/.env is for a workstation. Under Actions the values come from secrets
# and variables, and a stray .env on the runner must not override them.
if [ -z "${GITHUB_ACTIONS:-}" ] && [ -f "$ci/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ci/.env"
    set +a
fi

CI_NET=${CI_NET:-172.31.0}
CI_GW=${CI_GW:-$CI_NET.1}
CI_DNS=${CI_DNS:-1.1.1.1 9.9.9.9}
CI_POOL=${CI_POOL:-ci}
PVE_API_URL=${PVE_API_URL:-https://$CI_GW:8006}
PVE_NODE=${PVE_NODE:-}
PVE_STORAGE=${PVE_STORAGE:-local-zfs}
PVE_IMPORT_STORAGE=${PVE_IMPORT_STORAGE:-local}
PVE_BRIDGE=${PVE_BRIDGE:-vmbr1}
repo=$(cd "$ci/.." && pwd)

die() { echo "error: $*" >&2; exit 1; }
log() { echo "-- $*" >&2; }

# Collapsible sections in the Actions log, plain headers elsewhere.
group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else echo "== $*"; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "$c is required"; done; }

# Everything one set keeps between scripts: its ssh key, known_hosts, the
# node list it was brought up with. A dev cluster's lives in ci/.state so
# it survives; under Actions it is the job's temp dir, gone with the job.
state_dir() {
    local d
    d=${CI_STATE_DIR:-${RUNNER_TEMP:+$RUNNER_TEMP/wpci}}
    d=${d:-$ci/.state}/$1
    mkdir -p "$d" && chmod 700 "$d"
    echo "$d"
}

# The nodes of a set as "vmid name os octet flavor cores mem balloon disk",
# from what up.sh recorded (a --small dev cluster is two of four), else
# from nodes.conf.
set_nodes() {
    local st
    st=$(state_dir "$1")
    if [ -f "$st/nodes" ]; then
        cat "$st/nodes"
    else
        conf_nodes "$1"
    fi
}
conf_nodes() { awk -v s="$1" '$1 == s { $1 = ""; sub(/^ /, ""); print }' "$ci/nodes.conf"; }

# Control sockets live in a short path of their own: a Unix socket path is
# limited to 108 bytes, and the state dir plus %C's 40 hex chars is not.
cm_dir() {
    local d=${XDG_RUNTIME_DIR:-/tmp}/wpci-$(id -u)
    mkdir -p "$d" && chmod 700 "$d"
    echo "$d"
}

# ssh to a node as ci. The VMs are recreated with fresh host keys every run,
# so a per-set known_hosts is trusted on first use and wiped by up.sh -- the
# CI bridge is reachable only from the host and the allowlisted LAN hosts.
ssh_opts() {
    local st
    st=$(state_dir "$1")
    printf '%s ' -i "$st/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o ConnectTimeout=5 -o ServerAliveInterval=15 -o LogLevel=ERROR \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$st/known_hosts" \
        -o ControlMaster=auto -o "ControlPath=$(cm_dir)/%C" -o ControlPersist=120
    [ -z "${CI_JUMP:-}" ] || printf '%s ' -J "$CI_JUMP"
}

# on <set> <ip> <shell command...>: run on the node. ssh reads stdin, so
# inside a `while read` loop give it </dev/null or it eats the loop's input.
on() {
    local s=$1 ip=$2; shift 2
    # shellcheck disable=SC2046
    ssh $(ssh_opts "$s") "ci@$ip" "$*"
}

# Quote one argument for the remote shell.
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# wp <set> <ip> <waterpump args...>: run the CLI from the installed tree.
wp() {
    local s=$1 ip=$2 cmd a; shift 2
    cmd="cd ~/waterpump && ./waterpump"
    for a in "$@"; do cmd="$cmd $(q "$a")"; done
    on "$s" "$ip" "$cmd"
}

# wait_ssh <set> <ip> [tries]: until sshd answers and cloud-init is done.
# `cloud-init status` needs root on Fedora (it reads /run/cloud-init/cloud.cfg,
# 0600), and boot-finished is the fallback while sudo is not set up yet. Each
# try is bounded: a session opened during first boot can hang for good when
# cloud-init regenerates the host keys under it, so no control master either
# (ssh takes the first -o given, hence before ssh_opts).
wait_ssh() {
    local i=0
    # shellcheck disable=SC2046
    until timeout 300 ssh -o ControlMaster=no -o ControlPath=none $(ssh_opts "$1") "ci@$2" \
        'timeout 240 sudo -n cloud-init status --wait >/dev/null 2>&1 ||
            test -f /var/lib/cloud/instance/boot-finished' </dev/null 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -lt "${3:-60}" ] || die "$2 never answered on ssh"
        sleep 5
    done
}
