# ci/ -- the cluster CI environment

Scripts that bring up four fresh VMs on a dedicated Proxmox host, install
waterpump on them, federate them and run `ci/tests/` against the cluster. The
same scripts serve `cluster.yml` in GitHub Actions and a person at a workstation.
docs/development.md has the why. This file is the how. Every script takes
`--help` (or `-h`), which prints its usage and works without `ci/.env`.

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
  IPv6 is off on every VM: the network has none, and the snap store stalls
  when a VM tries it.
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
ci/dev-cluster.sh login         # each node's UI (https://172.31.0.31:8099 ...) and the login
ci/task-setup.sh dev            # pin:golden-task-image, template golden-task, task test-task every 5 min
ci/dev-cluster.sh update        # push the checkout again, keep the cluster
ci/dev-cluster.sh test          # run ci/tests against it
ci/dev-cluster.sh down
```

`up --small` gives you two nodes (Ubuntu/LXD + Debian/Incus).

Every set has the managed `large` and `small` node groups (`cluster group
auto`). The VMs of a set are of one size, so each is in both unless
`nodes.conf` gives them different cores or memory.

Every set has local logins turned on. `cluster.sh` makes one admin user,
`tester` (or `CI_LOGIN_USER`), with a random 20-character password that
works on every node, and keeps it in `ci/.state/<set>/login` (mode 600). It
is never printed, CI log included. The CLI on a node needs no login.
Open any node's address over the route from `ci/workstation-route.sh`; the
certificate is the node's own, self-signed. Without the route,
`ci/dev-cluster.sh ui 1` tunnels node 1 to https://localhost:8099.

The dev cluster and a CI run exclude each other. A CI run started while the
dev cluster is up fails at once with a message saying so.

## The CI run, by hand

```sh
ci/up.sh ci && ci/install.sh ci && ci/cluster.sh ci && ci/tests/run.sh ci
ci/collect.sh ci /tmp/logs       # what a failing run uploads
ci/down.sh ci
```

## Logging in to a node

Every node has a `ci` user with passwordless sudo. Each set has its own key,
made by `up.sh` and removed by `down.sh` with the rest of `ci/.state/<set>/`,
so with nothing up `ci/.state` is gone:

```sh
ssh -i ci/.state/ci/id_ed25519 -o UserKnownHostsFile=ci/.state/ci/known_hosts ci@172.31.0.21
```

The dev set also accepts this workstation's `~/.ssh/id_*.pub`, so
`ssh ci@172.31.0.31` or `ci/dev-cluster.sh ssh 1` is enough there.

## Templates

`ci-images.yml` rebuilds every template weekly; `ci/build-templates.sh [os...]`
does it by hand. The new template goes into the OS's free VMID slot and the
old one is removed afterwards, unless a running set still has linked clones
of it: then it stays until the next build.

- `KEEP_FAILED=1 ci/build-templates.sh <os>` keeps a failed build VM running
  and adds your `~/.ssh/id_*.pub` to it, for a look around.
- **Adding an OS:** a line in `images.conf`, a script `images/<os>.sh` (run as
  root between `common-pre.sh` and `common-post.sh`; use `ci_pkgs`,
  `ci_lxd_snap` or `ci_incus`), and a node in `nodes.conf`. A script that
  exits 100 asks for a reboot and is then run again, at most twice: for a new
  kernel or a boot argument.

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
