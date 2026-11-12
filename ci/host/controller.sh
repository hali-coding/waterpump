#!/bin/sh
# Build the controller VM: the self-hosted GitHub Actions runner for
# cluster.yml and ci-images.yml. Run from a workstation that has the route
# to the CI bridge (ci/workstation-route.sh) and sudo on the host (PVE_SSH).
#
#   ci/host/controller.sh               # create the VM and install the runner
#   ci/host/controller.sh --register    # also register it with GitHub (asks gh)
#
# The controller is deliberately *outside* the `ci` pool, so the token the
# jobs run with cannot touch it. It sits on vmbr1 only -- it needs the API
# and the internet, not the LAN -- and is reached as admin@<CI_NET>.10.
# The runner itself runs as `runner`, with no sudo and no ssh login.
set -eu
ci=$(cd "$(dirname "$0")/.." && pwd)
. "$ci/lib/common.sh"
[ -n "${PVE_SSH:-}" ] || die "PVE_SSH is not set (ci/.env)"

VMID=${CONTROLLER_VMID:-100}
NAME=wpci-controller
IP=$CI_NET.10
IMAGE_URL=https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2
LABEL=waterpump-cluster
register=
[ "${1:-}" = --register ] && register=yes

host() { ssh -o BatchMode=yes "$PVE_SSH" "sudo sh -c $(q "$*")"; }
admin() { ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "admin@$IP" "$@"; }

if host "qm status $VMID" >/dev/null 2>&1; then
    log "VM $VMID exists, skipping creation"
else
    keys=$(cat ~/.ssh/id_*.pub)
    [ -n "$keys" ] || die "no ~/.ssh/id_*.pub to install for admin"
    printf '%s\n' "$keys" | ssh -o BatchMode=yes "$PVE_SSH" "cat > /tmp/wpci-controller.keys"
    log "creating $NAME ($VMID) at $IP"
    host "set -e
        cd /var/lib/vz/import
        wget -q -N $IMAGE_URL
        qm create $VMID --name $NAME --ostype l26 --cpu host --cores 2 \
            --memory 1024 --balloon 768 --agent 1 --onboot 1 \
            --scsihw virtio-scsi-single \
            --scsi0 $PVE_STORAGE:0,import-from=$PVE_IMPORT_STORAGE:import/$(basename "$IMAGE_URL"),discard=on,ssd=1 \
            --ide2 $PVE_STORAGE:cloudinit --boot order=scsi0 --serial0 socket --vga serial0 \
            --net0 virtio,bridge=$PVE_BRIDGE \
            --ipconfig0 ip=$IP/24,gw=$CI_GW --nameserver '$CI_DNS' \
            --ciuser admin --sshkeys /tmp/wpci-controller.keys \
            --description 'waterpump CI: GitHub Actions runner (ci/host/controller.sh)'
        qm resize $VMID scsi0 20G
        qm start $VMID
        rm -f /tmp/wpci-controller.keys"
fi

log "waiting for ssh on $IP"
i=0
until admin 'cloud-init status --wait >/dev/null 2>&1; true' 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 60 ] || die "$IP never answered (is the route to $CI_NET.0/24 in place?)"
    sleep 5
done

ver=$(curl -sSf https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name | sed 's/^v//')
log "installing packages and actions runner $ver"
admin "sudo sh -s" <<EOF
set -e
# IPv6 off, as on every CI VM (images/common-pre.sh): the network has none.
printf '%s\n' 'net.ipv6.conf.all.disable_ipv6 = 1' 'net.ipv6.conf.default.disable_ipv6 = 1' \
    'net.ipv6.conf.lo.disable_ipv6 = 1' > /etc/sysctl.d/90-wpci-no-ipv6.conf
sysctl -q -p /etc/sysctl.d/90-wpci-no-ipv6.conf
export DEBIAN_FRONTEND=noninteractive
apt-get -q update >/dev/null
apt-get -y -q -o Dpkg::Lock::Timeout=300 install qemu-guest-agent curl jq git python3 \
    openssh-client ca-certificates unattended-upgrades >/dev/null
systemctl enable --now qemu-guest-agent 2>/dev/null || systemctl start qemu-guest-agent
id runner >/dev/null 2>&1 || useradd -m -s /bin/bash runner
passwd -l runner >/dev/null
cd /home/runner
if [ ! -x actions-runner/config.sh ] || [ "\$(cat actions-runner/.version 2>/dev/null)" != "$ver" ]; then
    mkdir -p actions-runner
    curl -sSfL https://github.com/actions/runner/releases/download/v$ver/actions-runner-linux-x64-$ver.tar.gz \
        | tar xz -C actions-runner
    echo "$ver" > actions-runner/.version
    chown -R runner:runner actions-runner
    actions-runner/bin/installdependencies.sh >/tmp/runner-deps.log 2>&1 || { tail -5 /tmp/runner-deps.log; exit 1; }
fi
EOF

if [ -z "$register" ]; then
    log "installed, not registered: run again with --register to attach it to GitHub"
    exit 0
fi
need gh
slug=$(cd "$ci/.." && gh repo view --json nameWithOwner --jq .nameWithOwner)
token=$(gh api -X POST "repos/$slug/actions/runners/registration-token" --jq .token)
log "registering $NAME with $slug (label $LABEL)"
# The token goes over stdin, never on a command line another user could read.
printf '%s\n' "$token" | admin "sudo -u runner sh -c 'cd ~/actions-runner && read -r t &&
    ./config.sh --unattended --url https://github.com/$slug --token \"\$t\" \
        --name $NAME --labels $LABEL --replace >/dev/null' &&
    sudo sh -c 'cd /home/runner/actions-runner && ./svc.sh install runner >/dev/null && ./svc.sh start >/dev/null'"
# (svc.sh as root inside the cd: /home/runner is 0700, so admin cannot cd there.)
admin "systemctl is-active 'actions.runner.*'"
