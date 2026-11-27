# Fabrics: networking between nodes

[← Experimental features](experimental.md) · [README](../README.md)

> **Experimental, and off by default.** Switch fabrics on in **Settings →
> Experimental features**, or with `waterpump features-set --enable fabrics`.
> See [Experimental features](experimental.md) for what the switch does.

This page is about networks between waterpump's own instances across nodes. To
put instances on your LAN, addressed by your router, see
[Containers on your LAN](lan.md).

A managed bridge is NAT'd. That is right for reaching the internet and wrong
for reaching a container on another host: the source address is rewritten to
the host's, and there is no route back. So by default a container on one node
cannot open a connection to a container on another, even when the hosts are
sitting on the same switch.

A **fabric** fixes that. It is one bridge on every node, each on a /24 of its
own out of a prefix the whole cluster shares, with a host route from every node
to every other node's /24. An instance that joins gets a NIC on it:

```
  container on nodeA                         container on nodeB
    eth0 -> lxdbr0      NAT'd                  eth0 -> lxdbr0      NAT'd
    eth1 -> pumpfab1   10.101.2.31            eth1 -> pumpfab1   10.101.4.18
              |   route 10.101.0.0/16 via eth1           |
        nodeA 192.168.1.10 ---------- LAN ---------- nodeB 192.168.1.11
             ip route 10.101.4.0/24 via 192.168.1.11
```

A cluster can have several fabrics, each with its own prefix. Each is named
after the bridge it puts on every node, so a stack can keep its database tier
on one and its web tier on another.

## What a fabric lets through

- **Within the fabric, routed.** Instances reach each other across nodes by
  their own addresses. Nothing is NAT'd on the way, so the receiver sees who
  really called.
- **Into the fabric, nothing else.** A bridge only accepts traffic from its own
  fabric's prefix, or replies to connections its instances started. A host on
  your LAN, a container on `lxdbr0`, and an instance on another fabric are all
  dropped.
- **Every node reaches every instance.** A node's own traffic into a fabric
  leaves from its fabric gateway address (the routes carry it as `src`), so it
  is inside the prefix and let in on every other node -- not only its own
  instances. Forwarded traffic ignores the hint, so a plain container still
  arrives from the host's LAN address and is dropped.
- **Once a macvlan network exists anywhere in the cluster,** every node also
  admits the LAN subnet it is on, so instances on that LAN reach every fabric
  (see [LAN networks and fabrics](#lan-networks-and-fabrics)). That opens the
  fabrics to the whole of that LAN, which is the trade: a device there that
  adds a route can reach fabric instances too.
- **Out of the fabric, NAT'd** (the default). Traffic for anywhere else leaves
  behind the host's address, like any managed bridge. A NAT'd fabric also
  offers a gateway over DHCP, so an instance can have the fabric as its *only*
  NIC and still reach the internet.
- **Without NAT** (`--no-nat`, or the checkbox in the UI), a fabric carries
  traffic within itself and nothing else. It offers no gateway, and anything
  sent elsewhere through it is dropped.

waterpump enforces this with an nftables table of its own, `ip waterpump`, next to
the daemon's `inet lxd` / `inet incus`. It is rebuilt whole on every apply. The
daemon's own `ipv4.nat` stays off on fabric bridges because it would
masquerade traffic to the other nodes' /24s as well.

## What this version needs

- **Every node on one L2 network.** Routing is plain `ip route … via <host>`:
  no tunnel, no encryption, no NAT traversal. `waterpump fabric status` checks
  that each peer is directly reachable and says so if not, rather than leaving
  you with a route that silently drops.
- **Traffic between nodes is in the clear** on your LAN, as it would be between
  two hosts on that LAN.
- **sudo for one command**, below. Without it everything still works except
  writing routes and the firewall, and `waterpump fabric plan` prints what to run
  yourself.
- **iproute2 and nftables** on every node (`ip`, `nft`).

Not in this version: IPv6 on a fabric, and cross-node name resolution. An
instance is reached by address, not by name.

## Creating one

From the **Network** tab, choose **New network** → *Shared across the cluster
(fabric)*. The next step asks every node what
it already uses (every interface the daemon can see *and* every route in the
host's table, so a VPN's range counts too) and proposes a name and the first
free /16. Each edit is checked again, and the dialog shows which /24 each node
would get before anything is made.

Or from the CLI, on any node:

```bash
sudo ./systemd/install-service.sh --fabric   # once per node
waterpump fabric check                     # what would be picked, and does it fit?
waterpump fabric create                    # pumpfabN on the first free /16, NAT on
waterpump fabric create db --prefix 10.120.0.0/20 --no-nat
```

A prefix is a private /16 to /22 (at most 254 nodes, at least 4). The node you
create it on goes first, then the others side by side; each creates its bridge
and programs its routes and firewall.

**Every node in the cluster must be reachable.** A node that does not answer
cannot be checked for what it already uses, and it would have no way to catch
up later, because nothing reconciles a subnet claim. So while any member is
down, the fabric step names it and will not create, and `fabric create` is
refused. Bring the node
back, or, if it is gone for good, evict it (**Evict** on the Cluster tab, or
`waterpump cluster evict NAME`). Eviction works on a node that cannot be reached:
instead of telling it to stand down, it rotates the cluster credential so the
node can no longer act as a member.

A node that joins the cluster later is given a subnet in every fabric as part
of joining. If that failed, or a node joined while a fabric was being made,
the fabric shows it as *not on it* and **Add missing nodes**
(`waterpump fabric extend NAME`) allocates the rest.

```bash
waterpump fabric list   # every fabric, and each node's part in it
waterpump fabric status  # this node: its subnets, bridges and routes
waterpump fabric plan   # the exact host commands, to run yourself
waterpump fabric apply  # create the bridges, program routes and firewall
waterpump fabric delete db  # remove it from every node
waterpump fabric leave [NAME]  # this node only
```

Deleting is refused while a template names the fabric (as its extra NIC or
as its network), and while any instance on any node still has a NIC on the
fabric. As with deleting a network, waterpump does not detach them for you,
because an instance whose NIC goes keeps running, cut off.

## Putting instances on one

```bash
waterpump create web -i images:alpine/3.21 --fabric pumpfab1
waterpump create solo -i images:alpine/3.21 --network pumpfab1  # the fabric as its only NIC
waterpump template-save web --image images:alpine/3.21 --fabric pumpfab1
waterpump fabric attach existing-instance --fabric pumpfab1   # and `detach`
```

In the UI, fabrics are a group in the **Network** picker of the create and
template dialogs. A fabric with NAT becomes the instance's only NIC (as
`--network` does); one without NAT is added beside the default network (as
`--fabric` does), since it carries nothing else. On the CLI, a bare `--fabric`
means the one fabric this node is on. A template names its
fabric. A node that is not on it launches the instance anyway, without the
NIC, and says so in the run notes. That is the same substitution a template
gets for a pool or a network the node does not have.

Attaching a NIC only gives an instance a *link*: almost every image configures
`eth0` alone. waterpump configures the interface inside the instance as well,
persistently where the image has somewhere to persist it (systemd-networkd or
`/etc/network/interfaces`), and adds the route to the whole fabric prefix
through it. Without that route, traffic to another node's /24 would follow the
default route out of `eth0` and arrive NAT'd behind the host.

### Stacks

This is what makes a stack spanning several nodes work. A step's `{{step.ip}}`
and `{{step.ips}}` hand on the *fabric* address when the instance has one, so a
later step reaches the earlier one wherever it landed. Without a fabric they
hand on a node-local address that means nothing on another host.

## Privilege

waterpump reads the routing table and `/proc/sys` without privilege, so status
and the plan always work. It needs root to write routes and the firewall, and
the shipped rules (`systemd/waterpump-fabric.sudoers`, installed to
`/etc/sudoers.d/waterpump-fabric` by `install-service.sh --fabric`) grant exactly
one command:

```
%lxd ALL=(root) NOPASSWD: /path/to/waterpump fabric-helper
```

The helper reads a *description of the wanted state* on stdin (subnets and the
host each belongs to) and works out the commands itself. Nothing the caller
sends is executed:

- every route must be a /24 inside one of this node's fabric prefixes, reached
  through a directly-connected network;
- every bridge named must be one of this node's fabrics;
- the firewall is built from this node's saved fabric settings alone, so stdin
  cannot add a rule;
- removing a route is held to ownership rather than to the prefixes. waterpump
  marks its routes with protocol 133 and only ever lists those, which is what
  lets a deleted fabric's routes be cleared once its prefix is gone.

It is a command of waterpump's own rather than `ip` for two reasons worth
knowing before you edit that file:

- **`ip` cannot be granted safely.** Without arguments it allows
  `ip netns exec X sh`, which is a root shell.
- **Argument patterns do not confine portably.** Ubuntu 25.10 ships sudo-rs,
  which matches command arguments literally and supports neither wildcards nor
  regular expressions; classic sudo supports both. A pattern that confines on
  Debian is wide open or simply broken on Ubuntu.

The same helper also converts a NIC into a bridge for
[Containers on your LAN](lan.md#privilege), under confinement of the same kind.

The grant goes to the daemon's own admin group (`lxd` or `incus-admin`), which
[docs/security.md](security.md) already treats as root-equivalent: creating a
container on a host is enough to become root on it. Fabrics add no access that
group did not already have.

## Docker hosts

Docker sets the host's `FORWARD` policy to `DROP`, which blocks everything
crossing between bridges. It looks like a working fabric until traffic is
tried. On a host with Docker's `DOCKER-USER` chain, the helper keeps an accept
rule for each fabric bridge there, tagged `waterpump-fabric`, and removes it when
the fabric goes. Isolation is unaffected, because a drop in waterpump's own
table still drops. Without the helper, `waterpump fabric status` prints the
rules to add yourself.

## When it does not work

**`serve` cannot program routes.** The shipped systemd units set
`NoNewPrivileges=yes`, which stops sudo raising privilege at all. That is the
same thing that breaks PAM password logins. On the system unit, set
`NoNewPrivileges=no`. On the **user** unit that is not enough: the filesystem
sandbox runs in a user namespace where sudo cannot work at all, so it has to go
too ([the drop-in](service.md#a-user-unit-that-can-raise-privilege)). Or run
`waterpump fabric apply` yourself; the result is identical. This failure is
quiet: `fabric create` still reports success. The sign is `fabric list`
showing every node as `routes`, with each peer's route missing.

**A node shows `routes` or `no bridge`.** It was told about the fabric but has
not stood it up, usually for want of privilege there. Run
`waterpump fabric apply` on that node; its row says which route is missing.

**A peer's route shows `unreachable`.** Its address is not on a network this
host is directly attached to. This version routes rather than tunnels, so the
nodes have to share an L2 network.

**The prefix collides.** `fabric check` names what it overlaps and on which
node, and a blank prefix proposes one that fits everywhere.

**The name is taken on a node.** A fabric's bridge takes the fabric's name, so
a node that already has a network by that name -- one a fabric did not make --
refuses its subnet rather than re-addressing that network. This mostly shows
up on a node that joined later. Rename or delete the network there, then run
`waterpump fabric extend NAME`.

## In the web UI

The top of the **Network** tab is **Fabrics**. Each fabric has a card with its prefix,
whether it NATs, and one row per node: the /24 that node holds, its gateway,
how many of its routes to the other nodes are in place, which instances are
attached, and a state (*ok*, *no bridge*, *routes*, *not on it*, *no answer*).
Each row is the node's own report, fetched from it, so a missing bridge or
route on another host shows up here rather than as lost packets. The card
polls every 10 seconds, because every poll asks each member.

The fabric step of **New network** is pre-filled with the first free name and /16,
checked against every interface and route on every node. Editing either field
checks again, shows the /24 each node would get, and names the node and
interface that any overlap is with. The fabric is created on every node at
once, so every node must be reachable: while one is not, the step says which
node it is, that the way on without it is to evict it on the Cluster tab, and
will not create.
**Add missing nodes** gives a subnet to members that lack one, and **Delete**
removes the fabric everywhere once no instance is attached to it. **Apply**
and **Show plan** act on this node's routes and firewall.

In the create and template dialogs, fabrics are a group of their own in the
**Network** picker, so there is one choice to make. A fabric with NAT becomes
the instance's only NIC: it reaches the fabric on every node directly and the
internet through the NAT. A fabric without NAT cannot carry internet traffic,
so it is added as a second NIC beside the default network. The hint under the
picker says which of the two you get.

## LAN networks and fabrics

An instance on a [macvlan network](lan.md) reaches every fabric
instance in the cluster, on any node, by its fabric address:

- **Routes in the instance.** At launch waterpump gives it a static route to each
  node's fabric subnet, via that node's LAN address -- and to its own host's
  via the host's fabric gateway (below). They are kept where the guest's
  network manager keeps them: a drop-in for the interface's own
  systemd-networkd file (so networkd does not clear them as foreign), or an
  ifupdown `if-up.d` hook elsewhere (Alpine, Debian without networkd). When
  fabrics or members change, waterpump writes them again into every running
  macvlan instance on that node, on the same clock as fabric routes.
- **The fabrics let the LAN in.** Every member publishes which LAN subnets its
  macvlan networks are on, and every fabric firewall admits them. That is the
  whole subnet, not just waterpump's instances: any device on that LAN that adds
  a route can reach fabric instances.
- **The host shim.** macvlan never passes frames between a NIC and its own
  macvlan instances, so on its own the host could not reach them, nor they its
  fabric. waterpump adds a small macvlan interface to the host (`wpmp-<nic>`, no
  address) that its instances *can* reach, plus a `/32` route per instance
  through it (route protocol 134, apart from the fabric's 133), sending from the
  host's own address on that LAN. What a fabric instance opens towards one is
  SNAT'd to that address too (`ip waterpump_shim`). The shim is removed with the
  last macvlan instance on that host. As a side effect the host now reaches
  its own macvlan instances.

An instance that has a fabric NIC as well already routes the whole prefix
through it, and is left alone. The shim and the per-instance routes need the
root helper; without it, an instance still reaches every *other* node's
fabric.

## Maintenance

A node in [maintenance](cluster.md#maintenance) takes no fabric changes:
creating, extending or deleting a fabric that would touch it waits until it is
back, and on the node itself fabric claims, attaching and detaching are
refused. Its own routes are left exactly as they were, and brought up to date
when maintenance ends. `waterpump fabric apply` on the node still works: it
only programs what the node already claims, which is how routes come back
after a reboot during maintenance.

A template launched on a node that is not on its fabric launches without that
NIC, so those instances are reachable only on their own host. The run's notes
and that node's log say so:

```
! nodeC: This node is not on the fabric pumpfab1; launched without its NIC, so these instances can only be reached from this host.
```

## Under systemd

The helper raises privilege through `sudo`, which `NoNewPrivileges=yes` in the
shipped units blocks. On the system unit, set `NoNewPrivileges=no`; on the
user unit, use [the drop-in](service.md#a-user-unit-that-can-raise-privilege).
Either way, you can instead program the routes yourself with `waterpump fabric
apply`; the result is identical.

## Settings

`waterpump configure fabric` sets the one thing that is per node: the address
peers route this node's subnets to (by default the one its cluster URL names).
The fabrics themselves are each a subnet the cluster allocated. They are kept
in the same file, but only ever written by waterpump.

## API

| Endpoint | What it does |
| --- | --- |
| `GET /api/fabrics` | every fabric in the cluster, and each node's own report of its part (asks every member) |
| `GET /api/fabrics/check?name=&prefix=` | would this fabric fit on every node? Blank fields are filled with the first free name and /16 |
| `POST /api/fabrics` | create a fabric on every node: `{name, prefix, nat}`, any of them may be omitted |
| `POST /api/fabrics/{name}/extend` | give every member that lacks one a subnet in it |
| `DELETE /api/fabrics/{name}` | remove it from every node; refused while a template names it or any instance is attached |
| `GET /api/fabric` | this node's half: its subnet, bridge and per-peer routes in each fabric |
| `GET /api/fabric/host` | what this host already uses, which `check` asks each member for |
| `GET /api/fabric/plan` | the host commands that would bring routes and firewall up to date |
| `POST /api/fabric/apply` | create the bridges, program the routes and the firewall |
| `POST /api/fabric/instances/{name}/attach` | give an instance a NIC on a fabric, `{fabric}` (`detach` removes it) |

`PUT` and `DELETE /api/fabric/claims/{name}` exist too, but are members-only:
they are how the node a fabric is created or deleted on tells each peer.
Setting one node's subnet by hand is how two nodes end up holding the same
range.
