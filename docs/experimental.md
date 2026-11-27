# Experimental features

[← back to README](../README.md)

waterpump's everyday work is templates, instances and tasks. These two
features go further, and suit someone who already knows those well:

| Feature | What it is | Read more |
| --- | --- | --- |
| **Stacks** | Templates launched in stages, each handed the names and addresses of the earlier ones, with health gates, scripts and load-test swarms, operated as one deployment. | [Stacks](stacks.md) |
| **Fabrics** | A routed network across every node, each with its own /24, so instances on different hosts reach each other directly. | [Fabrics](fabrics.md) |

Both are **off on a new install**. Their tab and menu entries are hidden, and
creating one is refused, until someone switches the feature on. Experimental
means they are less exercised than the rest: the cluster tests in `ci/tests/`
cover instances and tasks on every host, not these, and how they work may
still change between releases.

## Switching them on and off

In the web UI: **Settings → Experimental features**. From the CLI:

```bash
waterpump features                          # what is on, and what holds each on
waterpump features-set --enable stacks      # or fabrics; repeatable
waterpump features-set --disable fabrics
waterpump configure features                # the same, asked interactively
```

Over the API: `GET /api/features` and `PUT /api/features`
(`{"settings": {"stacks": true, "fabrics": false}}`, admin). `/api/status`
carries the flags in force as `features`.

It is **one setting for the whole cluster**, saved on one node and pushed to
every member like a template, so no node hides something another is using.
Three rules keep a switch from breaking anything that already runs:

- **An upgrade hides nothing.** On a node where nobody has chosen yet, a
  feature is on if anything of it exists: a saved stack, or a fabric claimed by
  any member. A new install starts with both off, and a cluster already using
  them keeps them on.
- **Off refuses new things and never tears anything down.** With stacks off,
  saving a stack is refused (`409`). With fabrics off, `fabric check`,
  `create` and `extend` are. Nothing that exists is touched: routes, bridges
  and instances stay as they are, and deleting, stopping and destroying still
  work.
- **Switching off is refused while anything of it exists** on any member
  that answers. The answer names what is in the way and where (`409`).
  Delete the stacks or fabrics first, everywhere they are.

A member running a waterpump from before the switch existed knows no
`features` setting: it reports the push as not synced, carries on, and shows
both features as it always did.

[LAN networks](lan.md) are not part of either switch.

## Stacks

A stack launches templates in order, hands each step what earlier steps made
(`{{db.ip}}`), waits on health gates, runs scripts, and operates the result as
one deployment: stop, start, relaunch, destroy, load-test with swarms, and
report. [Stacks](stacks.md) covers designing, launching and operating one.

With stacks on, they reach into the rest of waterpump in these places:

- **Web UI.** A **Stacks** tab under Workloads (marked *beta*), a Stacks tile
  and list on **Home**, and each instance's stack in the Containers table and
  drawer.
- **Templates.** A stack's launch step names a template, so deleting a template
  a stack launches is refused (`409`, naming the stacks). A template's
  **Replace stale** leaves out instances a stack launched: they carry values
  the stack rendered for them, so the stack's own **Replace stale** refreshes
  those. An instance's `stale` lists `stack` when its stack has changed since
  it was launched.
- **Node groups.** Deleting a group a stack's launch step targets is refused
  (`409`).
- **Maintenance.** A stack launch is refused on a node in maintenance, like a
  template launch; it checks before its first stage, so a relaunch is refused
  before anything is torn down.
- **Sync.** Stacks are pushed to every member with the templates they launch,
  and reconciled like them. `waterpump cluster sync --kind stacks` (and
  `stack-secrets`) pushes them by hand.
- **`waterpump top`.** A stacks panel, with relaunch, start, stop, restart,
  destroy and cancel. See [Stacks](stacks.md#in-waterpump-top).
- **Roles.** An operator may launch, relaunch, stop, start and destroy a
  stack and cancel its runs; saving one is admin.
- **Security.** A script step is the one thing in waterpump that runs code on
  a host on purpose, and a stack's secrets can be revealed to an admin who
  confirms their password. See [Stacks](stacks.md#security).
- **Service.** Stopping `serve` stops a running swarm and destroys its
  instances first. See [Stacks](stacks.md#swarms-load-tests-against-a-running-stack).
- **API.** Every `/api/stacks`, `/api/stack-runs` and `/api/stack-instances`
  route is listed in [Stacks](stacks.md#api).

## Fabrics

A fabric is one bridge on every node, each on a /24 of a prefix the cluster
shares, with a host route from every node to every other node's /24.
Instances on it reach each other by their own addresses whichever host they
are on. It needs the nodes on one L2 network and a sudo rule for its helper.
[Fabrics](fabrics.md) covers creating one, putting instances on it, privilege
and troubleshooting.

With fabrics on, they reach into the rest of waterpump in these places:

- **Web UI.** A **Fabrics** section at the top of the Network tab, and a
  *Shared across the cluster* choice in **New network**. Fabrics form their own
  group in the create and template dialogs' **Network** picker. See
  [Fabrics](fabrics.md#in-the-web-ui).
- **Templates.** A template's `fabric` (or a NAT'd fabric as its `network`)
  puts each instance on it; it counts towards a template's revision, so
  changing it makes instances stale. A node that is not on the fabric launches
  without that NIC and says so in the run's notes. Deleting a fabric a
  template names is refused.
- **Maintenance.** Creating, extending or deleting a fabric that would touch a
  node in maintenance waits until it is back. See
  [Fabrics](fabrics.md#maintenance).
- **LAN networks.** A macvlan instance reaches every fabric, and every fabric
  admits the LAN subnets members publish. See
  [Fabrics](fabrics.md#lan-networks-and-fabrics).
- **Running as a service.** The helper raises privilege through `sudo`, which
  `NoNewPrivileges=yes` blocks. See
  [Fabrics](fabrics.md#under-systemd).
- **API.** Every `/api/fabrics` and `/api/fabric` route is listed in
  [Fabrics](fabrics.md#api).
- **Stacks.** With both features on, a stack step's `{{db.ip}}` is the
  fabric address when there is one, so it means something on every node.
