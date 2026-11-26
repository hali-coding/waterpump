# waterpump

**Run instances and jobs on LXD and Incus, reliably, across every host you
have, whatever OS each one runs.**

waterpump manages system containers and VMs on a mix of hosts as one place.
You describe an instance once, as a **template**, and launch as many as you
need on any node. You describe a job once, as a **task**, and the cluster runs
it in a throwaway instance on a schedule, on demand or from a GitHub webhook,
at most once per occurrence, on whichever node is up. Every instance gets
health checks, and the UI, CLI and `waterpump top` show them live.

![waterpump's Home view across a six-node cluster](docs/screenshots/home.jpg)

```
  template "web"  (Debian 13, 2 CPU, apache2)       node-a  Ubuntu · LXD
  waterpump launch web -n 3 --group all       ──▶    web-1
                                                    node-b  Debian · Incus
  task "nightly-dump"  cron 0 2 * * *        ──▶    web-2   task-nightly-dump-…  (destroyed after)
                                                    node-c  Fedora · Incus
                                                    web-3
```

## Why waterpump

- **Stable on mixed hosts.** A cluster may mix LXD and Incus on different
  distributions. The integration tests run on a four-node cluster of Ubuntu,
  Debian, Fedora and AlmaLinux hosts, LXD and Incus each at their oldest
  supported version and a recent one. Modules are POSIX `sh`, so they run on
  minimal images without bash.
- **Plain system containers and VMs.** You get the speed and density of
  LXD/Incus without rebuilding your workloads as OCI images first.
- **Jobs that run once, wherever there is room.** A task is placed on node
  groups, and the cluster votes so each scheduled run happens at most once,
  even when a node is down or its clock is wrong.
- **A cluster with no control plane.** Each node is a complete waterpump.
  Nodes join with one code, there is no leader and no quorum, and losing a
  host costs you that host only. Templates, tasks and modules sync to every
  node as you save them.
- **Health you can see.** Every instance gets machine checks (responsive,
  load, near limits) plus your own Nagios-style app check.
- **One API, three front ends.** The web UI, the CLI and the REST API are the
  same thing: `--json` on any command prints exactly what the API returns.
- **Nothing to install.** The backend is stdlib-only Python 3.10+, with no pip,
  virtualenv or database. The release archive ships with the UI already built.

<table>
<tr>
<td width="50%"><a href="docs/screenshots/instance.jpg"><img src="docs/screenshots/instance.jpg" alt="Instance drawer"></a><br><b>Every instance, any node:</b> health, app check, resources, snapshots, bootstrap and a live console.</td>
<td width="50%"><a href="docs/screenshots/monitor.jpg"><img src="docs/screenshots/monitor.jpg" alt="Monitor view"></a><br><b>Watch the cluster</b>: CPU, memory and network for every node and instance, live.</td>
</tr>
</table>

## How it fits together

Each building block is made from the one before it:

| | What it is | Read more |
| --- | --- | --- |
| **Module** | A POSIX shell script that configures an instance (packages, users, services), with parameters and never-stored secrets. | [modules](docs/modules.md) |
| **Template** | A whole instance: image, container or VM, limits, network, modules and an app health check. Launch one or many, recreate or destroy them together. | [templates](docs/templates.md) |
| **Instance** | A container or VM on one node, made from a template or by hand, with health checks, snapshots, limits and a console. | [web UI](docs/web-ui.md) |
| **Task** | A job run in a throwaway instance, on a cron schedule, on demand or from a GitHub webhook. The cluster votes so that each occurrence runs at most once. | [tasks](docs/tasks.md) |
| **Nodes** | Hosts joined with one code, each with its own daemon. Launches and tasks land on node groups; `all` is every member. | [nodes](docs/cluster.md) |

Two more are **experimental and off by default**. Switch them on in
**Settings → Features**, or with `waterpump features-set --enable stacks`.
They suit someone who already knows the rest:

| | What it is | Read more |
| --- | --- | --- |
| **Stack** | Templates launched in stages, each handed the names and addresses of the earlier ones, with health gates, scripts and load-test swarms. | [stacks](docs/stacks.md) |
| **Fabric** | A routed network across every node, so instances reach each other whichever host they are on. | [networking](docs/networking.md) |

![The Cluster view: six nodes mixing LXD and Incus, with groups, maintenance and sync](docs/screenshots/cluster.jpg)

## Getting started

**1. Check the prerequisites.** You need **LXD or Incus** with its daemon
running (`snap install lxd`, or `apt install incus` on Debian 13+), and
**Python 3.10+**. Your user must be in the daemon's admin group, `lxd` or
`incus-admin`. Check with `id`; after `sudo usermod -aG lxd $USER`, log out
and back in.

**2. Download and start it.** The release archive already contains the built
UI:

```bash
curl -LO <repo>/releases/latest/download/waterpump-<version>.tar.gz
tar xzf waterpump-<version>.tar.gz && cd waterpump-<version>
./waterpump serve --open          # opens http://127.0.0.1:8099
```

The first start is *unconfigured mode*: it listens on `127.0.0.1` only, has no
login and serves plain HTTP. Nothing off this host can reach it, so it is safe
to look around. If the daemon has never been set up, press **Initialize** (or
run `./waterpump init`) to create a storage pool, a bridge and a default
profile.

**3. Turn on logins and HTTPS.** Press **Configure node** in the banner. Choose
an admin username and password, a certificate (generate a self-signed one, or
upload your own) and whether to listen on every interface. waterpump saves
everything and restarts itself, then the browser continues at `https://` and
asks for the new login. With a self-signed certificate, the browser warns once.
Compare the fingerprint the dialog shows before accepting it. From a shell, run
`./waterpump configure node` and then restart `serve`.

**4. Add people and tokens.** Accounts have a role: `read`, `operator` (run
and stop what exists) or `admin`. Add them in the **Access** tab, or:

```bash
./waterpump user-add alice --role operator   # asks for a password
./waterpump token-create ci --role read --expires 30d   # for scripts; shown once
```

To log in with host accounts (PAM) or through a reverse proxy instead, run
`./waterpump configure auth`. See [Security](docs/security.md).

**5. Keep it running.** Run `./systemd/install-service.sh` to install
waterpump as a systemd user service. It runs as you and uses the settings you
just saved. See [Running as a service](docs/service.md).

**6. Launch something.** Press **+ New** for a single container, or save a
template and launch several:

```bash
./waterpump template-save web -i images:debian/13 -c 1 -m 1GiB -b base -b apache2
./waterpump launch web -n 2
```

Then give a job to the cluster as a [task](docs/tasks.md):

```bash
./waterpump task-save hello -t web --script job.sh --group all --cron "*/15 * * * *"
./waterpump task-run hello            # run it now and wait
```

Building from a clone instead? Run `./build.sh` once to build the UI. It is the
only step that needs Node. See [Development](docs/development.md).

### Then add more hosts

waterpump works on one host, but it is built for several:

1. Set up each host as in steps 1–5, listening on every interface.
2. `waterpump cluster invite` on one, then `waterpump cluster join CODE` on the others.
3. Templates and tasks sync to every node. A task on group `all` can now run
   on any of them; `waterpump cluster group auto` also sorts nodes into
   `large` and `small`.
4. Launch templates on groups from any node: `waterpump launch web -n 6 --group all`.

## CLI

```
waterpump template-save NAME -i images:debian/13 -c 2 -b base
waterpump launch NAME -n 3 --group all     # a template over nodes
waterpump templates | modules | profiles

waterpump task-save NAME -t TEMPLATE --script FILE --group all --cron "0 2 * * *"
waterpump tasks | task-run NAME | task-runs NAME

waterpump features | features-set --enable stacks   # experimental: stacks, fabrics

waterpump cluster invite | join CODE | status | containers | group auto
waterpump cluster maintenance on     # keep new instances off this node
waterpump fabric create              # experimental: a routed network across every node
waterpump image-pin IMAGE            # one build, copied to every node, as pin:NAME

waterpump top                        # live view of nodes and instances, with a console
waterpump health | status | logs -f  # health, readiness, a live tail of who did what
waterpump ls | create | exec | shell | snapshot | bootstrap   # single instances
waterpump serve                      # web UI + API
```

Every command takes `--json` and prints exactly what the REST API returns:

```bash
waterpump cluster containers --json | jq -r '.instances[] | select(.template=="web") | .name'
```

`waterpump --help` lists everything, and `waterpump COMMAND --help` explains one.

## Documentation

| Doc | Covers |
| --- | --- |
| [Instance templates](docs/templates.md) | a full instance setup; app health checks |
| [Tasks](docs/tasks.md) | scheduled, invoked and webhook jobs; inputs; the vote on who runs each one |
| [Bootstrap modules](docs/modules.md) | writing modules, parameters, secrets, profiles, the shipped modules |
| [Nodes and federation](docs/cluster.md) | joining, groups, maintenance, sync and reconciliation, `waterpump top` |
| [Stacks](docs/stacks.md) | *experimental:* stages, handing values along, health gates, secrets, scripts, swarms and reports |
| [Networking between nodes](docs/networking.md) | *experimental:* fabrics, routed networks shared by every node |
| [Containers on your LAN](docs/lan.md) | addresses from your router: a bridge, macvlan, or the host's NIC |
| [Web UI tour](docs/web-ui.md) | Home, health, bulk actions, Storage, Network, Access and Settings |
| [Security](docs/security.md) | logins (local, PAM, proxy), roles, API tokens, TLS |
| [Running as a service](docs/service.md) | systemd units, user vs system install |
| [Logging](docs/logging.md) | who did what, the live tail, local and remote syslog |
| [REST API](docs/api.md) | every endpoint, with request and response shapes |
| [Daemons, images and storage](docs/daemons-and-storage.md) | LXD vs Incus, image remotes and pins, quotas, units |
| [Development](docs/development.md) | source layout, the Vite dev server, how releases are cut |

## Good to know

- **Not a host manager.** The host features (init, storage, bridges,
  maintenance) exist to get a node ready. Provisioning and patching hosts
  belong to other tools.
- **Not LXD/Incus clustering.** Each node talks to its own daemon, clustered
  or not, and a cluster may mix LXD and Incus.
- **Not a scheduler.** A launch's instances go round robin over the nodes it
  names. Nothing is moved when a host fails, and an instance belongs to the
  node that made it.
- **Members trust each other.** Nodes share one credential, so every node is an
  admin of every other. Only federate hosts you administer. See
  [Security](docs/security.md).
- Launches and stack runs happen on the server. Closing the browser doesn't
  stop them; stopping `serve` does.
