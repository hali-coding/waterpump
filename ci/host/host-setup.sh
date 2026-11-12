#!/bin/sh
# One-time (and re-runnable) preparation of the Proxmox host for waterpump CI.
# Runs as root ON the host; ci/host/apply.sh pipes it there with the
# settings from ci/.env as environment variables. Everything here is
# idempotent: running it again converges, it never duplicates.
#
# What it does, and why each piece is here rather than in a VM:
#   - vmbr1: the private CI bridge, no ports, the host at .1
#   - routing: forwarding on, NAT only towards the internet (not the LAN),
#     and only the allowlisted LAN hosts may open connections into vmbr1
#   - memory: ZFS ARC capped, KSM merging earlier -- RAM is the one thing a
#     16 GB host runs out of
#   - access: a `ci` pool, a role limited to it, and an API token. The CI
#     runner never gets ssh or root here; the token is all it has.
set -eu

CI_NET=${CI_NET:-172.31.0}
CI_TRUSTED_SRC=${CI_TRUSTED_SRC:-}
CI_POOL=${CI_POOL:-ci}
PVE_BRIDGE=${PVE_BRIDGE:-vmbr1}
PVE_UPLINK=${PVE_UPLINK:-vmbr0}
PVE_STORAGE=${PVE_STORAGE:-local-zfs}
PVE_IMPORT_STORAGE=${PVE_IMPORT_STORAGE:-local}
ARC_MAX_MB=${ARC_MAX_MB:-1024}
KSM_THRES_COEF=${KSM_THRES_COEF:-40}
ROTATE_TOKEN=${ROTATE_TOKEN:-}
node=$(hostname)

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
say() { echo "-- $*"; }

# --- the CI bridge -------------------------------------------------------------
# Through the API rather than editing /etc/network/interfaces, so the GUI
# shows it and `ifreload` applies it the way Proxmox expects.
if pvesh get "/nodes/$node/network/$PVE_BRIDGE" >/dev/null 2>&1; then
    say "$PVE_BRIDGE exists"
else
    say "creating $PVE_BRIDGE ($CI_NET.1/24)"
    pvesh create "/nodes/$node/network" --iface "$PVE_BRIDGE" --type bridge \
        --cidr "$CI_NET.1/24" --autostart 1 --comments "waterpump CI (private, NAT out)"
    pvesh set "/nodes/$node/network"
fi

# --- routing and firewall ---------------------------------------------------------
lan=$(ip -4 -o addr show dev "$PVE_UPLINK" | awk '{print $4; exit}')
[ -n "$lan" ] || { echo "no IPv4 address on $PVE_UPLINK" >&2; exit 1; }
lan_net=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_interface(sys.argv[1]).network)' "$lan")

echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-waterpump-ci.conf
sysctl -q -p /etc/sysctl.d/90-waterpump-ci.conf

trusted=$(echo "$CI_TRUSTED_SRC" | tr ' ' '\n' | grep . | paste -sd, -)
mkdir -p /etc/waterpump-ci
# One table, replaced whole on every load (declare, delete, declare): what
# is in the file is all there is, as with waterpump's own `ip waterpump`.
{
    echo "table inet wpci {}"
    echo "delete table inet wpci"
    echo "table inet wpci {"
    echo "  chain postrouting {"
    echo "    type nat hook postrouting priority srcnat; policy accept;"
    # Not towards the LAN: a routed workstation then sees a VM's real
    # address and the VM sees the workstation's, both ways.
    echo "    ip saddr $CI_NET.0/24 oifname \"$PVE_UPLINK\" ip daddr != $lan_net masquerade"
    echo "  }"
    echo "  chain forward {"
    echo "    type filter hook forward priority filter; policy accept;"
    echo "    ct state established,related accept"
    echo "    iifname \"$PVE_BRIDGE\" oifname \"$PVE_BRIDGE\" accept"
    [ -z "$trusted" ] || echo "    oifname \"$PVE_BRIDGE\" ip saddr { $trusted } accept"
    echo "    oifname \"$PVE_BRIDGE\" drop"
    # A test VM runs whatever a PR says: it may reach the internet, not the
    # LAN it sits behind.
    echo "    iifname \"$PVE_BRIDGE\" ip daddr $lan_net drop"
    echo "  }"
    # The forward chain never sees traffic *to* this host: whatever a VM
    # sends to any of the host's addresses (the bridge's .1 or its LAN IP)
    # is delivered locally through input. So the host is closed to the
    # bridge too, but for the API -- and that only from the controller
    # (ci/host/controller.sh puts it at .10), the one thing that calls it;
    # test VMs never do, and must not be able to try logins on it.
    echo "  chain input {"
    echo "    type filter hook input priority filter; policy accept;"
    echo "    iifname \"$PVE_BRIDGE\" ct state established,related accept"
    echo "    iifname \"$PVE_BRIDGE\" ip saddr $CI_NET.10 tcp dport 8006 accept"
    echo "    iifname \"$PVE_BRIDGE\" icmp type echo-request accept"
    echo "    iifname \"$PVE_BRIDGE\" drop"
    echo "  }"
    echo "}"
} > /etc/waterpump-ci/wpci.nft
cat > /etc/systemd/system/waterpump-ci-net.service <<EOF
[Unit]
Description=waterpump CI bridge NAT and forwarding rules
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/waterpump-ci/wpci.nft
ExecStop=/usr/sbin/nft delete table inet wpci

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable -q waterpump-ci-net.service
nft -f /etc/waterpump-ci/wpci.nft
systemctl start waterpump-ci-net.service
say "forwarding: $CI_NET.0/24 NAT out via $PVE_UPLINK, LAN $lan_net, trusted: ${trusted:-none}"

# --- memory ----------------------------------------------------------------------------
if [ -d /sys/module/zfs ]; then
    arc=$((ARC_MAX_MB * 1024 * 1024))
    if [ "$(cat /sys/module/zfs/parameters/zfs_arc_max)" != "$arc" ]; then
        say "ZFS ARC max -> ${ARC_MAX_MB} MB"
        echo "options zfs zfs_arc_max=$arc" > /etc/modprobe.d/zfs.conf
        echo "$arc" > /sys/module/zfs/parameters/zfs_arc_max
        # The root is on ZFS, so the module options live in the initramfs.
        update-initramfs -u -k all >/dev/null 2>&1
    fi
fi
# No host swap: this host's only fast disk is a ZFS pool, and swap on a
# zvol can deadlock under exactly the memory pressure it is there for.
# Ballooning and KSM are the slack instead. ksmtuned starts merging when
# free memory drops below KSM_THRES_COEF percent; the default 20 is late
# for four near-identical guests.
if [ -f /etc/ksmtuned.conf ]; then
    sed -i "s/^#\?\s*KSM_THRES_COEF=.*/KSM_THRES_COEF=$KSM_THRES_COEF/" /etc/ksmtuned.conf
    systemctl restart ksmtuned
fi

# --- access: pool, role, user, token --------------------------------------------------
pveum pool list --output-format json | grep -q "\"poolid\":\"$CI_POOL\"" \
    || pveum pool add "$CI_POOL" --comment "waterpump CI VMs and templates"

# What cloning, configuring, starting and deleting a VM needs, plus uploading
# a cloud image to import from. Granted only on the pool, the two storages
# and the CI bridge: nothing on / or on the node.
privs="VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit"
privs="$privs VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network"
privs="$privs VM.Config.Options VM.PowerMgmt VM.GuestAgent.Audit Datastore.AllocateSpace"
privs="$privs Datastore.AllocateTemplate Datastore.Audit SDN.Use Pool.Audit"
privs=$(echo "$privs" | tr ' ' ',')
if pveum role list --output-format json | grep -q '"roleid":"WaterpumpCI"'; then
    pveum role modify WaterpumpCI --privs "$privs"
else
    pveum role add WaterpumpCI --privs "$privs"
fi
pveum user list --output-format json | grep -q '"userid":"ci@pve"' \
    || pveum user add ci@pve --comment "waterpump GitHub Actions (API token only)"
for path in "/pool/$CI_POOL" "/storage/$PVE_STORAGE" "/storage/$PVE_IMPORT_STORAGE" \
            "/sdn/zones/localnetwork/$PVE_BRIDGE"; do
    pveum acl modify "$path" --users ci@pve --roles WaterpumpCI
done
# The import storage must accept cloud images.
content=$(pvesh get "/storage/$PVE_IMPORT_STORAGE" --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["content"])')
case ",$content," in *,import,*) ;; *) pvesm set "$PVE_IMPORT_STORAGE" --content "$content,import" ;; esac

# --- token ----------------------------------------------------------------------------
# privsep 0: the token has exactly the user's ACLs above, so there is one
# list of what CI may do, not two.
if pveum user token list ci@pve --output-format json | grep -q '"tokenid":"ci"'; then
    if [ -n "$ROTATE_TOKEN" ]; then
        pveum user token remove ci@pve ci
    else
        say "token ci@pve!ci exists (ROTATE_TOKEN=1 replaces it)"
    fi
fi
if ! pveum user token list ci@pve --output-format json | grep -q '"tokenid":"ci"'; then
    secret=$(pveum user token add ci@pve ci --privsep 0 --comment "waterpump CI" \
        --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["value"])')
    echo "PVE_TOKEN_ID=ci@pve!ci"
    echo "PVE_TOKEN_SECRET=$secret"
fi

cert=/etc/pve/local/pveproxy-ssl.pem
[ -f "$cert" ] || cert=/etc/pve/local/pve-ssl.pem
pin=$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform der \
      | openssl dgst -sha256 -binary | base64)
echo "PVE_TLS_PIN=sha256//$pin"
