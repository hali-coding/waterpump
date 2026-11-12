# Development

[← back to README](../README.md)

## Source layout

```
waterpump        # CLI entry point, runs from the checkout
src/waterpump/
  lxd.py           # LXD/Incus REST client over the unix socket
  service.py       # domain logic for this node, shared by the API and the CLI
  stacks.py        # stacks: staged launches, values between steps, health gates
  tasks.py, cron.py  # tasks: scheduled and invoked jobs, the vote on who runs each
  cluster.py       # federation: joining, groups, sync, reconciliation, cluster launches
  fabric.py        # fabrics: routed networks across nodes
  hostnet.py       # the host's routes and firewall -- the one place that shells out
  health.py        # health judgement, load sampling, app checks
  metrics.py       # the Monitor page's usage history, sampled by serve
  auth.py, pam.py  # logins, roles, API tokens
  server.py        # HTTP routing, JSON API, terminals, static hosting
  cli.py, top.py   # argparse front end; the live `waterpump top` view
  bootstrap.py     # module discovery, SSH key validation, the runner
  nodeclient.py    # REST client for another node, over pinned TLS
  store.py         # persistent state under ~/.local/share/waterpump
modules/           # bootstrap modules (POSIX sh); _prelude.sh is prepended to each
web/               # Vite + React + TypeScript UI; builds to web/dist, not in git
systemd/           # service units and installer
docs/              # the user documentation
```

The design behind those layers -- why each module is shaped the way it is --
is in [CLAUDE.md](../CLAUDE.md).

## Frontend

Only needed if you are changing the UI. `npm run dev` serves it with hot reload
on :5173 and proxies `/api` to the Python backend, so run both:

```bash
./build.sh                     # once: checks Node, installs, builds
./waterpump serve --dev      # terminal 1
npm --prefix web run dev       # terminal 2 → http://localhost:5173
```

Point the proxy somewhere else with `WATERPUMP_API=http://host:port npm run dev`.

`web/dist` is a build output and is **not** in git — it is rebuilt by the
release workflow and shipped inside the release archive. Build it once in a
clone, and again after changing anything under `web/src`:

```bash
./build.sh            # refuses early if Node is missing or too old
./build.sh --clean    # throw away web/dist and node_modules first
```

`./build.sh` is what CI runs too, so a clone and a release are built the same
way. Under it is just `npm --prefix web run build`, if you would rather drive
that directly. There is nothing to commit afterwards: `.gitignore` covers
`web/dist`.

## Python versions in CI

waterpump supports Python 3.10 and up with no dependencies, and `pr.yml` checks
both halves of that without a daemon:

- **Python (3.10, and the two newest releases):**
  - every module compiles and imports with nothing but the stdlib
  - deprecation warnings are errors, so an API on its way out fails on the
    newest Python before the release that removes it
  - every CLI command's help formats (`.github/scripts/check_cli.py`); a
    command's help is only built when someone asks for it
- **Python 3.10 API floor:** [vermin](https://github.com/netromdk/vermin) checks
  that nothing uses a stdlib member newer than 3.10. The 3.10 import check
  cannot see that inside a function body. vermin is a CI tool only. To run it
  locally: `uvx vermin --target=3.10- --violations --no-tips src/waterpump`.

The live-daemon job below then runs real code paths on the floor and the newest
Python.

## The live-daemon CI job

GitHub's hosted runners have no LXD or Incus, so the live-daemon check is a
workflow of its own, `daemon.yml`, run on a self-hosted runner labelled
`waterpump-daemon`. The runner is a small Debian 13 VM (2 vCPU, 1 GB) with
Incus. `pr.yml` calls it only after the hosted jobs pass, so a change that
fails those never takes the runner's time. It can also be started on its own
from the Actions tab, against any branch.

It runs `.github/scripts/daemon_smoke.sh` twice, one run after the other:
under Python 3.10 and under the newest release. Each interpreter comes from uv,
so nothing on the VM is set up by hand. You can also run the script by hand on
any host with a daemon. It covers:

- `status`
- a create on Alpine with the `base` module
- exec, including an exit code of 127
- snapshot and restore
- a template with an app check: save, launch two instances, `template-exec`
  (a failing command must fail the run), destroy
- `serve` answering the API
- a template launch handed to `serve`, and the run it reports at
  `/api/template-runs`
- template delete, then stop and delete

Every name in the script carries the run id and the Python version, and a
trap removes what the run made, because the VM is long-lived.

The repository is public, and the runner's user can drive the daemon, which is
as good as root on that VM. So:

- The job is skipped for PRs from forks. To check a fork's change, push it to
  a branch here.
- Every PR from an outside contributor needs approval before any workflow runs
  (Settings → Actions → General). The job's `if:` is not enough on its own: a
  PR's workflows run from the PR's copy of the files, so a fork could simply
  delete the condition.

## The cluster CI job

`cluster.yml` is what nothing else checks: federation, both daemons side by
side, and the OSes waterpump is installed on. Each run brings up four fresh VMs
on a dedicated Proxmox host:

- Ubuntu 26.04 on LXD 6 (the current LTS, snap)
- AlmaLinux 10 on LXD 5.21 (the previous LTS, snap), SELinux off
- Debian 13 on Incus 6.0 (LTS, Debian's package)
- Fedora 45 on Incus (a recent release, Fedora's package)

Each daemon runs on one node at the oldest version a cluster member may run
(`MIN_CLUSTER_VERSION` in `lxd.py`) and on one recent one, so a change that
only works on new daemons fails here rather than for a user.

It installs this commit as the ci user's systemd service on each VM, forms a
cluster, and runs `ci/tests/`. `pr.yml` calls it beside `daemon.yml`, gated the
same way. It can also be started by hand. Every step is a script under `ci/`
that also runs from a workstation. `ci/README.md` has the commands, and
`ci/dev-cluster.sh` keeps a cluster up for manual testing.

How it is put together, and why:

- **Templates, then linked clones.** `ci-images.yml` (weekly, or by hand)
  builds one template per OS. Each has the daemon installed and the test
  images pulled. A run takes ZFS linked clones of the newest templates and
  only sets each clone's address and key. That turns about ten minutes of
  installing per VM into seconds. A failed template build leaves the
  previous template in use.
- **RAM is the budget.** The host has 16 GB. Four VMs at 2.5 GB, with
  ballooning down to 1.5 GB, fit beside the host and the 1 GB controller. So
  one set runs at a time: every job shares the `waterpump-pve` concurrency
  group, and a dev cluster and a CI run refuse each other. That refusal is
  atomic: `up.sh` first creates an empty VM at a fixed VMID, which Proxmox
  lets only one caller do, and `down.sh` removes it last. Other settings
  serve the same budget:
  - The ZFS ARC is capped at 1 GB.
  - KSM starts merging early.
  - Guests swap to a 1 GB file, not to zram.
  - The UI is built on a hosted runner.
- **Fixed slots.** The CI set is always VMIDs 201–204. `up.sh` starts by
  destroying whatever is there, so a run that died is cleaned up by the
  next one. Every delete checks the VM's name against `ci/nodes.conf` first.
- **The runner holds nothing.** The runner is the controller VM. It sits
  outside the `ci` pool, and the jobs' API token (repository secrets
  `PVE_API_URL`, `PVE_TOKEN_ID`, `PVE_TOKEN_SECRET`, `PVE_TLS_PIN`) is
  limited to that pool. A job that runs hostile code can wreck CI VMs, not
  the host or the controller. The host's certificate is pinned by key, not
  trusted.
- **The network:**
  - The VMs are on a private bridge, `172.31.0.0/24`, NAT'd to the internet
    and barred from the LAN and from the host itself; only the controller
    may reach the host, and only its API.
  - Only the LAN hosts listed in `CI_TRUSTED_SRC` may connect in, through a
    static route via the host.
  - Each run's ssh key is generated in the job and gone with it.

The same rules as `daemon.yml` keep forks and Dependabot off the runner.

## Releases

Releases are cut by [release-please](https://github.com/googleapis/release-please)
from the commit history, so the version number is decided by what was merged,
not by anyone editing a file:

| Commit subject | Effect on `0.4.2` |
| --- | --- |
| `fix: ...`, `perf: ...`, `refactor: ...` | `0.4.3` |
| `feat: ...` | `0.5.0` |
| `feat!: ...`, or a `BREAKING CHANGE:` footer | `0.5.0` while the project is pre-1.0, `1.0.0` and up after |
| `docs: ...`, `chore: ...`, `ci: ...` | none |

The PR workflow rejects a PR title that is not a conventional commit, because a
squash merge turns that title into the commit subject — the whole input to the
version number above.

The flow, all in `.github/workflows/release.yml`:

1. A merge to `main` makes release-please open (or update) a release PR titled
   `chore(main): release <version>`. It holds the `CHANGELOG.md` entry and the
   bumped version in `pyproject.toml` and `src/waterpump/__init__.py`.
2. Merging that PR is the decision to release. release-please tags
   `v<version>` and creates the GitHub release.
3. The same run then does `npm ci && npm run build` and attaches
   `waterpump-<version>.tar.gz`, `.zip` and `SHA256SUMS`.

The archive is the runnable tree — launcher, `src/`, the built `web/dist`,
`modules/`, `systemd/` and the docs — so a user needs only Python 3.10+. Build
the same thing locally to see what a release will contain:

```bash
./build.sh
.github/scripts/bundle.sh 1.2.3     # -> dist/waterpump-1.2.3.{tar.gz,zip}
```

To force a version — the first `1.0.0`, say — put `Release-As: 1.0.0` in a
commit body, or add it to a commit on the release PR.

Two repository settings this depends on: **Allow GitHub Actions to create and
approve pull requests** (Settings → Actions → General), or release-please
cannot open its PR; and squash merging enabled, so PR titles are what lands on
`main`.

### The `RELEASE_PLEASE_TOKEN` secret

GitHub will not let one workflow run trigger another, so a release PR opened by
`github-actions[bot]` cannot start the PR workflow: the run is created and dies
immediately with *Actor is not allowed to trigger Actions workflows*. The
effect is that the one PR nobody wrote by hand is the one that goes unchecked.

Giving release-please a token that belongs to an account fixes it — the PR is
opened by that account, and CI treats it like any other. Create a
[fine-grained PAT](https://github.com/settings/personal-access-tokens) scoped to
this repository with **Contents: read and write** and **Pull requests: read and
write**, then store it as the repository secret `RELEASE_PLEASE_TOKEN`
(Settings → Secrets and variables → Actions).

It is optional: without the secret the workflow falls back to `GITHUB_TOKEN`,
which still tags and releases correctly — only the checks on the release PR are
lost, and they show as a startup failure rather than as nothing. Nothing else in
the repository needs the token, and a fine-grained PAT expires, so the red X
coming back on a release PR is the sign that it needs renewing.
