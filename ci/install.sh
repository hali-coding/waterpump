#!/bin/sh
# Install this checkout of waterpump on every node of a set, as the ci
# user's systemd service with the drop-in from docs/service.md:
#
#   ci/install.sh ci
#
# The tree is packed from the working directory, not from git, so a dev
# cluster can run uncommitted changes. web/dist must already be built
# (CI downloads it from the hosted web job); without it serve still runs
# the API and the UI is missing, which only a person would notice.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"

[ $# -ge 1 ] || usage
set=$1
st=$(state_dir "$set")
[ -f "$st/nodes" ] || die "set $set is not up (ci/up.sh $set)"
[ -f "$repo/web/dist/index.html" ] || log "warning: web/dist is not built; the nodes get no UI"

tarball=$st/waterpump.tar.gz
tar -C "$repo" -czf "$tarball" --exclude-vcs --exclude=./node_modules --exclude=./web/node_modules \
    --exclude=./.claude --exclude='__pycache__' --exclude=./ci/.state --exclude='./ci/.env*' \
    --exclude=./dist .

# Runs as ci on each node, with the tarball on stdin.
remote=$(cat <<'EOF'
set -eu
export XDG_RUNTIME_DIR=/run/user/$(id -u)
sudo loginctl enable-linger "$(id -un)"
# Wait for the user manager itself, not the D-Bus socket: without
# dbus-user-session (not every image or daemon pulls it in) there is no bus, and
# systemctl --user talks to systemd's private socket instead.
i=0
until systemctl --user is-system-running >/dev/null 2>&1 ||
      [ "$(systemctl --user is-system-running 2>/dev/null)" = degraded ]; do
    i=$((i+1))
    [ $i -lt 30 ] || { echo "the user manager for $(id -un) never came up"; exit 1; }
    sleep 1
done
systemctl --user stop waterpump.service 2>/dev/null || true
rm -rf ~/waterpump.new && mkdir ~/waterpump.new
tar -xzf - -C ~/waterpump.new
rm -rf ~/waterpump && mv ~/waterpump.new ~/waterpump

# Bound to every address, and the unit's sandboxing off: under a user
# manager ProtectSystem/ProtectHome/PrivateTmp run in a user namespace
# where sudo sees root's files as nobody's, and fabric-helper and PAM then
# fail silently (see docs/service.md). Written before the first start, so
# the service never comes up loopback-only.
d=~/.config/systemd/user/waterpump.service.d
mkdir -p "$d"
cat > "$d/ci.conf" <<UNIT
[Service]
ExecStart=
ExecStart=/usr/bin/python3 $HOME/waterpump/waterpump serve --host 0.0.0.0 --port 8099
NoNewPrivileges=no
ProtectSystem=no
ProtectHome=no
PrivateTmp=no
ReadWritePaths=
UNIT
cd ~/waterpump
./systemd/install-service.sh >/tmp/wp-install.log 2>&1 || { cat /tmp/wp-install.log; exit 1; }
sudo ./systemd/install-service.sh --fabric >/tmp/wp-fabric.log 2>&1 || { cat /tmp/wp-fabric.log; exit 1; }
systemctl --user restart waterpump.service
i=0
# /api/auth answers without a login: cluster.sh turns auth on, and an
# update reinstalls over that.
until curl -skf -o /dev/null https://127.0.0.1:8099/api/auth \
      || curl -sf -o /dev/null http://127.0.0.1:8099/api/auth; do
    i=$((i+1))
    if [ $i -ge 60 ]; then journalctl --user -u waterpump -n 40 --no-pager; exit 1; fi
    sleep 1
done
./waterpump status
EOF
)

group "install on $set"
pids=
while read -r vmid name os octet flavor _; do
    ( on "$set" "$CI_NET.$octet" "$remote" < "$tarball" > "$st/install-$name.log" 2>&1 ) &
    pids="$pids $!:$name"
done < "$st/nodes"
failed=
for p in $pids; do
    if wait "${p%%:*}"; then log "${p#*:}: installed"; else failed="$failed ${p#*:}"; fi
    sed 's/^/    /' "$st/install-${p#*:}.log"
done
endgroup
[ -z "$failed" ] || die "install failed on:$failed"
