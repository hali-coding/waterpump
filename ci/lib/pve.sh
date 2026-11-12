# Sourced after common.sh: the Proxmox REST API with curl and jq. Only the
# API, never ssh to the host -- the CI token is limited to the `ci` pool,
# which is what keeps a job that escapes away from everything else there.

need curl jq

[ -n "${PVE_TOKEN_ID:-}" ] && [ -n "${PVE_TOKEN_SECRET:-}" ] \
    || die "PVE_TOKEN_ID and PVE_TOKEN_SECRET are not set (ci/.env, or the repo's secrets)"
[ -n "${PVE_TLS_PIN:-}" ] || die "PVE_TLS_PIN is not set (ci/host/apply.sh saves it to ci/.env)"
[ -n "${PVE_NODE:-}" ] || die "PVE_NODE is not set: the Proxmox node's name (ci/.env, or the repo's PVE_NODE variable)"

# pve <METHOD> <path> [curl args...]: print the response's .data as JSON.
# -k with --pinnedpubkey: no CA can vouch for a self-signed host, so the
# key pin is the whole check, and curl still enforces it under -k.
pve() {
    local m=$1 p=$2 out code body; shift 2
    # The token reaches curl as a config line on stdin, never in its argv,
    # where any local user could read it from /proc while a call runs.
    out=$(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PVE_TOKEN_ID" "$PVE_TOKEN_SECRET" |
        curl -K - -sS -k --pinnedpubkey "$PVE_TLS_PIN" --max-time 300 \
        -X "$m" -w '\n%{http_code}' "$@" "$PVE_API_URL/api2/json$p") \
        || { echo "PVE $m $p: request failed" >&2; return 1; }
    code=$(printf '%s\n' "$out" | tail -n 1)
    body=$(printf '%s\n' "$out" | sed '$d')
    case $code in
        2??) printf '%s' "$body" | jq -c '.data' ;;
        *) echo "PVE $m $p: HTTP $code $(printf '%s' "$body" | jq -c '.errors // .message // .' 2>/dev/null || printf '%s' "$body")" >&2
           return 1 ;;
    esac
}
qm_path() { echo "/nodes/$PVE_NODE/qemu/$1"; }

# pve_task <upid-json>: wait for a task the API started; fail with its log.
pve_task() {
    local upid enc st exit_status
    # Empty means the call itself failed (pve prints .data, "null" at the
    # least, on success): `pve_task "$(pve ...)"` would otherwise pass it.
    [ -n "$1" ] || return 1
    upid=$(printf '%s' "$1" | jq -r '.')
    case $upid in UPID:*) ;; *) return 0 ;; esac
    enc=$(printf '%s' "$upid" | jq -sRr @uri)
    while :; do
        st=$(pve GET "/nodes/$PVE_NODE/tasks/$enc/status") || return 1
        [ "$(printf '%s' "$st" | jq -r .status)" = stopped ] && break
        sleep 2
    done
    exit_status=$(printf '%s' "$st" | jq -r .exitstatus)
    [ "$exit_status" = OK ] && return 0
    echo "task failed: $exit_status" >&2
    pve GET "/nodes/$PVE_NODE/tasks/$enc/log" -G --data-urlencode limit=30 \
        | jq -r '.[].t' >&2 || true
    return 1
}

# Every VM the token can see: vmid, name, status, template, tags.
pve_vms() { pve GET /cluster/resources -G --data-urlencode type=vm; }

# The name of VMID $1, or nothing when there is none.
pve_name_of() { pve_vms | jq -r --argjson id "$1" '.[] | select(.vmid == $id) | .name'; }

# pve_destroy <vmid> <expected-name>: stop and purge, but only the VM we
# think it is -- a VMID reused for something else is refused, not deleted.
pve_destroy() {
    local name
    name=$(pve_name_of "$1")
    [ -n "$name" ] || return 0
    [ "$name" = "$2" ] || die "VM $1 is '$name', not '$2': refusing to delete it"
    log "destroying $1 ($name)"
    if [ "$(pve GET "$(qm_path "$1")/status/current" | jq -r .status)" = running ]; then
        pve_task "$(pve POST "$(qm_path "$1")/status/stop" --data-urlencode timeout=30)"
    fi
    pve_task "$(pve DELETE "$(qm_path "$1")?purge=1&destroy-unreferenced-disks=1")"
}

# The newest template built for an OS: build-templates.sh names them
# wpci-<os>-<UTC timestamp>, so the name sorts by age.
pve_template_for() {
    pve_vms | jq -r --arg p "wpci-$1-" \
        '[.[] | select(.template == 1 and (.name | startswith($p)))] | sort_by(.name) | last | .vmid // empty'
}

# PVE wants sshkeys URL-encoded inside the form field (and %20, not +).
pve_sshkeys() { jq -sRr @uri "$@"; }
