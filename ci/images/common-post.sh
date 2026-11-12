# Appended to every images/<os>.sh: what each VM cloned from the template
# needs, then everything that must differ between clones taken away.

# 1 GB of swap on disk, never zram: zram is RAM, which is the one thing the
# host is short of. Ballooning does the rest.
if [ ! -f /swapfile ]; then
    if [ -f /etc/systemd/zram-generator.conf ] || [ -d /usr/lib/systemd/zram-generator.conf.d ] \
       || rpm -q zram-generator-defaults >/dev/null 2>&1; then
        # An empty config switches the generator off.
        : > /etc/systemd/zram-generator.conf
    fi
    fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
    chmod 600 /swapfile
    mkswap -q /swapfile 2>/dev/null || mkswap /swapfile >/dev/null
    command -v restorecon >/dev/null 2>&1 && restorecon /swapfile || true
    echo '/swapfile none swap defaults 0 0' >> /etc/fstab
fi

# Pre-pull the images tests launch, so a run downloads (almost) nothing.
# Copied with their aliases into the local store, and waterpump's own
# `images:` launches find the same fingerprint already there. A failure
# fails the build: a template missing them makes every run download them.
for img in $CI_PREPULL; do
    log "pre-pulling $img"
    if command -v incus >/dev/null 2>&1; then
        incus image copy "images:$img" local: --alias "$img" --auto-update -q
    else
        # The snap's lxc is not on root's PATH everywhere; a distro LXD's is.
        lxc=$(command -v lxc || echo /snap/bin/lxc)
        # An LXD without an `images:` remote (a distro package's: the old
        # linuxcontainers.org one stopped serving LXD) gets the one waterpump
        # itself uses for LXD (lxd.py REMOTES_BY_FLAVOR).
        "$lxc" remote list --format csv | grep -q '^images,' ||
            "$lxc" remote add images https://images.lxd.canonical.com --protocol simplestreams --public
        "$lxc" image copy "images:$img" local: --alias "$img" --auto-update -q
    fi
done

log "sealing the template"
# Every clone must get its own identity: machine-id (else every clone asks
# DHCP for the same address), ssh host keys, cloud-init's instance state
# (else it never re-runs to set the clone's IP and key).
cloud-init clean --logs --seed >/dev/null 2>&1 || cloud-init clean --logs
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /home/ci/.ssh/authorized_keys
if command -v apt-get >/dev/null 2>&1; then apt-get -q clean; else dnf -q clean all; fi
fstrim -a >/dev/null 2>&1 || true
sync
log "done"
