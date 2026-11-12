# ci/ -- the cluster CI environment

Scripts that bring up four fresh VMs on a dedicated Proxmox host, install
waterpump on them, federate them and run `ci/tests/` against the cluster. The
same scripts serve `cluster.yml` in GitHub Actions and a person at a workstation.
docs/development.md has the why. This file is the how.

| Node | OS | Daemon |
|---|---|---|
| 1 | Ubuntu 26.04 | LXD 6 LTS (snap `6/stable`) |
| 2 | Debian 13 | Incus 6.0 LTS (distro): the Incus floor |
| 3 | Fedora 45 | Incus, recent (distro) |
| 4 | AlmaLinux 10 | LXD 5.21 (snap `5.21/stable`, snapd from EPEL), SELinux off: the LXD floor |

The nodes are in `nodes.conf`, the images in `images.conf`, and each template's
provisioning in `images/`.

## Layout on the host

- **Host:** a dedicated Proxmox VE host (its name and address are in your
  `ci/.env`, never in the repo). Ours has 8 threads, 16 GB of RAM and ZFS on
  NVMe. RAM is the constraint: one set of four VMs at a time (~10 GB at peak).
- **Network:** `vmbr1` = `172.31.0.0/24`, with the host at `.1`. The host NATs
  traffic to the internet only. From the LAN, only `CI_TRUSTED_SRC` may
  connect in, and the VMs cannot reach the LAN. Nor the host itself: from
  the bridge it answers ping and, for the controller only, the API (8006).
- **VMs:**

  | VMID | What | IP |
  |---|---|---|
  | 100 | `wpci-controller`, the GitHub runner (`waterpump-cluster`), outside the `ci` pool | `.10` |
  | 9001–9004 / 9101–9104 | templates `wpci-<os>-<stamp>`, two slots each, newest wins | `.91–.94` while building |
  | 200 | `wpci-hold-<set>`, an empty VM that says which set holds the host (`pve_hold`) | – |
  | 201–204 | the `ci` set, created and destroyed every run | `.21–.24` |
  | 211–214 | the `dev` set (`dev-cluster.sh`), kept until taken down | `.31–.34` |
- **Access:** an API token `ci@pve!ci` with role `WaterpumpCI`. It covers the
  `ci` pool, the two storages and `vmbr1`, and nothing else.

## From zero

You need:
- a Proxmox VE host with ZFS storage (`local-zfs`; other storage works if
  `PVE_STORAGE` says so, but clones are then copies and the ARC cap is moot);
- a login on it with passwordless sudo, for `PVE_SSH`. Making it is the one
  manual step on the host;
- `gh`, logged in with admin rights on the repository.

```sh
cp ci/.env.example ci/.env          # then edit: PVE_NODE, PVE_SSH, PVE_LAN_IP, CI_TRUSTED_SRC
ci/host/apply.sh                    # host: bridge, NAT, firewall, ARC, KSM, pool, role, token;
                                    # writes PVE_TOKEN_SECRET and PVE_TLS_PIN into ci/.env
ci/workstation-route.sh --persist   # this workstation: route to the CI bridge via the host
ci/host/controller.sh --register    # the runner VM, registered with GitHub
ci/build-templates.sh               # the four templates (~10 min each)
for k in PVE_API_URL PVE_TOKEN_ID PVE_TOKEN_SECRET PVE_TLS_PIN; do
    grep "^$k=" ci/.env | cut -d= -f2- | gh secret set "$k"    # value on stdin, never argv
done
grep '^PVE_NODE=' ci/.env | cut -d= -f2- | gh variable set PVE_NODE
```

Secrets live in two places only: the gitignored `ci/.env` (mode 600) and the
repository's secrets. Nothing in `ci/` prints them: `apply.sh` writes the
token straight into `ci/.env`, and `pve()` hands it to curl on stdin, so it
never shows in `ps`.

Every step is idempotent and re-runnable. `ROTATE_TOKEN=1 ci/host/apply.sh`
issues a new token into `ci/.env`; then re-run the `gh secret set` loop above.

## A cluster to play with

```sh
ci/dev-cluster.sh up            # 4 nodes from this checkout (uncommitted changes included)
ci/dev-cluster.sh ssh 2         # shell on node 2 (Debian), in ~/waterpump
ci/dev-cluster.sh ssh 2 ./waterpump status   # or run one command there
ci/dev-cluster.sh ui 1          # https://localhost:8099 -> node 1's UI
ci/dev-cluster.sh update        # push the checkout again, keep the cluster
ci/dev-cluster.sh test          # run ci/tests against it
ci/dev-cluster.sh down
```

`up --small` gives you two nodes (Ubuntu/LXD + Debian/Incus).

The dev cluster and a CI run exclude each other. A CI run started while the
dev cluster is up fails at once with a message saying so.

## The CI run, by hand

```sh
ci/up.sh ci && ci/install.sh ci && ci/cluster.sh ci && ci/tests/run.sh ci
ci/collect.sh ci /tmp/logs       # what a failing run uploads
ci/down.sh ci
```

## Adding a test

Drop `ci/tests/NN-name.sh` in. Tests run in name order against a formed
cluster. A test is plain sh, sourced with these available:

| Name | What it is |
|---|---|
| `$SET` | the set the test runs against |
| `$NODES` | the node list file, one node per line (`vmid name os octet flavor ...`) |
| `$FIRST_IP` | the node the cluster was started on |
| `wp <set> <ip> <args>` | runs `./waterpump <args>` on a node |
| `on <set> <ip> <cmd>` | runs a shell command on a node |
| `ip_of <name>` | a node's address |
| `fail <msg>` | fails the test |

Clean up what a test creates, even on failure (`trap`): a dev cluster is reused.
