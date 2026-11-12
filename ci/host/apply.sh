#!/bin/sh
# Run host-setup.sh on the Proxmox host with this checkout's ci/.env.
#
#   ci/host/apply.sh                 # converge the host
#   ROTATE_TOKEN=1 ci/host/apply.sh  # ... and issue a new API token
#
# A new token secret and the TLS pin go straight into ci/.env (created from
# .env.example if missing, mode 600) and are never printed. Then copy them to
# the repository's secrets (ci/README.md, "From zero").
set -eu
ci=$(cd "$(dirname "$0")/.." && pwd)
. "$ci/lib/common.sh"
[ -n "${PVE_SSH:-}" ] || die "PVE_SSH is not set (ci/.env)"

env_file=$ci/.env
[ -f "$env_file" ] || cp "$ci/.env.example" "$env_file"
chmod 600 "$env_file"

# set_env NAME VALUE: replace or add NAME= in ci/.env. The value reaches awk
# through the environment, which other users cannot read, not its argv.
set_env() {
    NAME=$1 VALUE=$2 awk 'BEGIN { n = ENVIRON["NAME"]; v = ENVIRON["VALUE"] }
        index($0, n "=") == 1 { print n "=" v; done = 1; next } { print }
        END { if (!done) print n "=" v }' "$env_file" > "$env_file.new"
    chmod 600 "$env_file.new"
    mv "$env_file.new" "$env_file"
}

out=$(mktemp)
chmod 600 "$out"
trap 'rm -f "$out"' EXIT
ssh -o BatchMode=yes "$PVE_SSH" "sudo env \
    CI_NET=$(q "$CI_NET") CI_TRUSTED_SRC=$(q "${CI_TRUSTED_SRC:-}") CI_POOL=$(q "$CI_POOL") \
    PVE_BRIDGE=$(q "$PVE_BRIDGE") PVE_UPLINK=$(q "${PVE_UPLINK:-vmbr0}") \
    PVE_STORAGE=$(q "$PVE_STORAGE") PVE_IMPORT_STORAGE=$(q "$PVE_IMPORT_STORAGE") \
    ROTATE_TOKEN=$(q "${ROTATE_TOKEN:-}") sh -s" < "$ci/host/host-setup.sh" > "$out"

# Everything but the PVE_* lines is progress for the operator.
grep -v '^PVE_[A-Z_]*=' "$out" || true
grep '^PVE_[A-Z_]*=' "$out" | while IFS= read -r line; do
    name=${line%%=*}
    set_env "$name" "${line#*=}"
    log "saved $name to ci/.env"
done
grep -q '^PVE_TOKEN_SECRET=.' "$env_file" ||
    log "warning: ci/.env has no PVE_TOKEN_SECRET; an existing token cannot be shown again, ROTATE_TOKEN=1 issues a new one"
