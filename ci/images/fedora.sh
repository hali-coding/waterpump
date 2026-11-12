# Fedora + Incus from Fedora's own repositories. SELinux stays enforcing:
# a denial there is a finding, not something to switch off.
ci_pkgs incus incus-tools
# Unprivileged containers need root's subordinate ids, which Fedora's
# package does not add.
grep -q '^root:' /etc/subuid || echo 'root:1000000:1000000000' >> /etc/subuid
grep -q '^root:' /etc/subgid || echo 'root:1000000:1000000000' >> /etc/subgid
ci_incus
ci_firewalld incusbr0
