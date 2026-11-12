# Ubuntu 26.04 + LXD from snap: the way most LXD users get it.
LXD_CHANNEL=${LXD_CHANNEL:-6/stable}
ci_pkgs snapd
ci_lxd_snap
