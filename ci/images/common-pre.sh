# Prepended to every images/<os>.sh by build-templates.sh, run as root in
# the template VM over ssh. POSIX sh: these are four different /bin/sh's.
set -eu
log() { echo "[$(hostname)] $*"; }

# ci_pkgs <pkgs...>: install with whichever package manager this OS has.
ci_pkgs() {
    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Lock::Timeout=600 install "$@" >/dev/null
    else
        dnf -y -q install "$@" >/dev/null
    fi
}
ci_upgrade() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get -q update >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Lock::Timeout=600 full-upgrade >/dev/null
    else
        dnf -y -q upgrade --refresh >/dev/null
    fi
}

# A snap LXD, the same way on every OS that uses one.
ci_lxd_snap() {
    snap wait system seed.loaded
    # The store is the one download here with no mirror; give a blip a
    # second chance and say plainly when it is the store that is down.
    local i=0
    until snap install lxd --channel="$LXD_CHANNEL"; do
        i=$((i + 1))
        [ "$i" -lt 3 ] || { log "snap install failed: is api.snapcraft.io reachable?"; return 1; }
        # A client that gave up leaves snapd's change running; a retry
        # started on top of it is refused ("change in progress").
        snap watch --last=install >/dev/null 2>&1 || true
        sleep 30
    done
    # Clones must run the LXD the template was built with: an auto-refresh
    # in the middle of a CI run restarts the daemon under the tests.
    snap refresh --hold lxd
    /snap/bin/lxd waitready --timeout=300
    /snap/bin/lxd init --auto
    groupadd -f lxd
    usermod -aG lxd ci
}

ci_incus() {
    systemctl enable --now incus.socket incus.service 2>/dev/null || systemctl enable --now incus
    incus admin init --auto
    usermod -aG incus-admin ci
}

# Peers call each other on 8099 and the daemon's bridge must be able to
# DHCP and NAT -- only matters where firewalld is on (Fedora/Alma, if the
# image enables it).
ci_firewalld() {
    systemctl is-active -q firewalld 2>/dev/null || return 0
    firewall-cmd -q --permanent --zone=trusted --add-interface="$1"
    firewall-cmd -q --permanent --add-port=8099/tcp
    firewall-cmd -q --reload
}

# IPv6 off, for good: the CI network has none, and with it on the snap
# store's downloads stall or reset (the VMs see IPv6 but cannot use it).
# Persistent, so clones and the daemons they run are IPv4-only too, which
# is the network waterpump is tested on here.
cat > /etc/sysctl.d/90-wpci-no-ipv6.conf <<'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSCTL
sysctl -q -p /etc/sysctl.d/90-wpci-no-ipv6.conf

log "upgrading"
ci_upgrade
# Provision on the kernel the clones will boot: a daemon initialised on the
# image's old kernel, or a module only the upgraded kernel's packages
# carry, would otherwise be tested against the wrong one.
# Exit 100 asks build-templates.sh to reboot and run everything again,
# which is why every step here and in images/<os>.sh is safe to re-run.
newest=$(ls /lib/modules | sort -V | tail -n 1)
if [ "$newest" != "$(uname -r)" ]; then
    log "rebooting into $newest (running $(uname -r))"
    exit 100
fi
ci_pkgs qemu-guest-agent python3 git curl jq tar
systemctl enable --now qemu-guest-agent 2>/dev/null || systemctl start qemu-guest-agent
