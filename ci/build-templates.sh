#!/bin/sh
# Build the golden template for each OS in images.conf (or those named):
#
#   ci/build-templates.sh               # all of them
#   ci/build-templates.sh fedora alma   # just these
#
# Each template is a VM with the OS upgraded, its daemon installed and
# initialised, and the images tests use already pulled -- so a CI run
# clones it (a ZFS linked clone: instant, nearly no space) instead of
# spending minutes installing a daemon on every VM it starts.
#
# A template is built under a new, timestamped name in whichever of its
# two VMID slots is free; up.sh always takes the newest. The old one is
# removed only after the new one is finished, so a failed build leaves CI
# on the last good template rather than on none.
set -eu
ci=$(cd "$(dirname "$0")" && pwd)
. "$ci/lib/common.sh"
. "$ci/lib/pve.sh"
need ssh ssh-keygen

CI_PREPULL=${CI_PREPULL:-alpine/3.22}
CI_CACHE=${CI_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/waterpump-ci}
mkdir -p "$CI_CACHE"

# The newest file in a directory listing matching a pattern (Fedora's
# image names carry a build number).
resolve_url() {
    case $1 in
        */) name=$(curl -fsSL "$1" | grep -o "$2" | sort -V | tail -n 1)
            [ -n "$name" ] || die "nothing matching $2 at $1"
            echo "$1$name" ;;
        *) echo "$1" ;;
    esac
}

keep_for_debugging() {
    cat ~/.ssh/id_*.pub 2>/dev/null | on "$set_name" "$ip" 'cat >> ~/.ssh/authorized_keys' </dev/null 2>/dev/null ||
        log "could not add ~/.ssh/id_*.pub; use ci/.state/$set_name/id_ed25519"
    log "kept $name ($vmid) for debugging: ssh ci@$ip (sudo works)"
}

build() {
    os=$1 idx=$2 octet=$3 url=$4 pattern=$5
    set_name=build-$os
    st=$(state_dir "$set_name")
    rm -f "$st/known_hosts"
    [ -f "$st/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C "wpci-$set_name" -f "$st/id_ed25519"
    ip=$CI_NET.$octet

    url=$(resolve_url "$url" "$pattern")
    file=$CI_CACHE/$os.qcow2
    group "$os: fetch $url"
    # -z: only download when the remote is newer than what is cached.
    if [ -f "$file" ]; then
        curl -fsSL -z "$file" -o "$file.new" "$url"
        if [ -s "$file.new" ]; then mv "$file.new" "$file"; else rm -f "$file.new"; fi
    else
        curl -fsSL -o "$file" "$url"
    fi
    upload=wpci-$os.qcow2
    volid=$PVE_IMPORT_STORAGE:import/$upload
    # An upload under the same name replaces the last one, so one file per OS
    # is all import storage ever holds (deleting it would need
    # Datastore.Allocate, which the CI role deliberately lacks).
    pve_task "$(pve POST "/nodes/$PVE_NODE/storage/$PVE_IMPORT_STORAGE/upload" --max-time 1800 \
        -F content=import -F "filename=@$file;filename=$upload")"
    endgroup

    # Two slots per OS: 9000+n and 9100+n. Build into the free one.
    old=$(pve_template_for "$os")
    vmid=$((9000 + idx))
    [ "$old" = "$vmid" ] && vmid=$((9100 + idx))
    other=$(pve_name_of "$vmid")
    if [ -n "$other" ]; then
        case $other in wpci-"$os"-*) ;; *) die "slot $vmid holds '$other'" ;; esac
        pve_destroy "$vmid" "$other"
    fi
    name=wpci-$os-$(date -u +%Y%m%dt%H%M)

    group "$os: create $name ($vmid)"
    # KEEP_FAILED=1 leaves a failed build running to look at, with this
    # machine's ~/.ssh/id_*.pub let in as ci (passwordless sudo) beside the
    # build key; the next build of that OS clears it.
    if [ -n "${KEEP_FAILED:-}" ]; then
        trap 'keep_for_debugging' EXIT
    else
        trap 'pve_destroy "$vmid" "$name" || true' EXIT
    fi
    pve_task "$(pve POST "/nodes/$PVE_NODE/qemu" \
        --data-urlencode "vmid=$vmid" --data-urlencode "name=$name" \
        --data-urlencode "pool=$CI_POOL" --data-urlencode ostype=l26 \
        --data-urlencode cpu=host --data-urlencode cores=4 --data-urlencode memory=2048 \
        --data-urlencode agent=1 --data-urlencode scsihw=virtio-scsi-single \
        --data-urlencode "scsi0=$PVE_STORAGE:0,import-from=$volid,discard=on,ssd=1" \
        --data-urlencode "ide2=$PVE_STORAGE:cloudinit" --data-urlencode "boot=order=scsi0" \
        --data-urlencode serial0=socket --data-urlencode vga=serial0 \
        --data-urlencode "net0=virtio,bridge=$PVE_BRIDGE" \
        --data-urlencode "ipconfig0=ip=$ip/24,gw=$CI_GW" --data-urlencode "nameserver=$CI_DNS" \
        --data-urlencode ciuser=ci --data-urlencode "sshkeys=$(pve_sshkeys "$st/id_ed25519.pub")" \
        --data-urlencode "description=waterpump CI template, $os, from $url")"
    # Tags only once the VM exists: on create Proxmox checks them against
    # /vms/<id>, which is not yet in the pool, and refuses the whole create.
    pve PUT "$(qm_path "$vmid")/config" --data-urlencode "tags=wpci-template;$os" >/dev/null
    pve PUT "$(qm_path "$vmid")/resize" --data-urlencode disk=scsi0 --data-urlencode size=12G >/dev/null
    pve_task "$(pve POST "$(qm_path "$vmid")/status/start")"
    wait_ssh "$set_name" "$ip" 120
    endgroup

    group "$os: provision"
    # Exit 100 from a script means "reboot me and run me again" (it upgraded
    # the kernel; see common-pre.sh), so the scripts are written to be
    # re-run. A new kernel and a kernel argument (Alma's selinux=0) are one
    # reboot each; a third is a reboot loop.
    tries=0
    while :; do
        rc=0
        cat "$ci/images/common-pre.sh" "$ci/images/$os.sh" "$ci/images/common-post.sh" \
            | on "$set_name" "$ip" "sudo env CI_PREPULL=$(q "$CI_PREPULL") sh -s" || rc=$?
        [ "$rc" -eq 100 ] && [ "$tries" -lt 2 ] || break
        tries=$((tries + 1))
        log "$os: rebooting"
        # The control master dies with the VM; drop it rather than wait it out.
        # shellcheck disable=SC2046
        ssh $(ssh_opts "$set_name") -O exit "ci@$ip" </dev/null 2>/dev/null || true
        pve_task "$(pve POST "$(qm_path "$vmid")/status/reboot" --data-urlencode timeout=180)"
        sleep 10
        wait_ssh "$set_name" "$ip" 120
    done
    [ "$rc" -eq 0 ] || die "$os: provisioning failed ($rc)"
    endgroup

    group "$os: seal"
    pve_task "$(pve POST "$(qm_path "$vmid")/status/shutdown" --data-urlencode timeout=180)"
    # The provisioning key was only for the build; clones get their own.
    pve PUT "$(qm_path "$vmid")/config" --data-urlencode delete=sshkeys >/dev/null
    pve_task "$(pve POST "$(qm_path "$vmid")/template")"
    trap - EXIT
    if [ -n "$old" ]; then
        oldname=$(pve_name_of "$old")
        # Fails while a dev cluster still has linked clones of it; the next
        # build retires it instead.
        pve_destroy "$old" "$oldname" || log "kept $oldname ($old): still has clones"
    fi
    endgroup
    log "$os: template $name ($vmid)"
}

wanted=${*:-$(awk '!/^#/ && NF { print $1 }' "$ci/images.conf")}
idx=0
awk '!/^#/ && NF' "$ci/images.conf" | while read -r os octet url pattern; do
    idx=$((idx + 1))
    case " $wanted " in *" $os "*) ;; *) continue ;; esac
    # One at a time: a build is a 2 GB VM, and a dev cluster may be up.
    # Not as `( build ) || die`: on the left of || errexit is off, even in
    # the subshell, and a failed step would carry on to the next.
    set +e
    ( set -e; build "$os" "$idx" "$octet" "$url" "$pattern" ) </dev/null
    rc=$?
    set -e
    [ "$rc" = 0 ] || die "$os: template build failed"
done
