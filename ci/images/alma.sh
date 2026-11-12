# AlmaLinux 10 + LXD 5.21 from the snap (snapd from EPEL): the oldest LXD
# a cluster member may run (lxd.py MIN_CLUSTER_VERSION, the previous LTS),
# on an EL host.
LXD_CHANNEL=${LXD_CHANNEL:-5.21/stable}
# SELinux off: EPEL 10's snapd-selinux policy does not build against the
# EL 10.2 base policy (it names the removed sys_resource_type attribute),
# so with SELinux on every snap mount fails. EL 10 no longer honours
# SELINUX=disabled in /etc/selinux/config, so it is a kernel argument, and
# a reboot (exit 100, as for a new kernel).
if [ "$(getenforce)" != Disabled ]; then
    log "disabling SELinux (selinux=0)"
    grubby --update-kernel ALL --args selinux=0
    exit 100
fi
# snapd mounts every snap as squashfs, which the cloud image's kernel-core
# leaves to kernel-modules. common-pre.sh has already rebooted into the
# newest kernel, so the package installed here is the running kernel's.
ci_pkgs epel-release kernel-modules
modprobe squashfs
ci_pkgs snapd
systemctl enable --now snapd.socket
[ -e /snap ] || ln -s /var/lib/snapd/snap /snap
ci_lxd_snap
ci_firewalld lxdbr0
