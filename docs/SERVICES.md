# `mesh services` — service control plane

One set of verbs to control the runtime state of every daemon the mesh installs,
across platforms (systemd on WSL/Linux · `brew services` / launchd on mac), over
the **two orthogonal bits** every service has: **active** (running now) and
**enabled** (autostart at boot/login).

## TL;DR

```sh
mesh services                      # interactive: filter → pick service → pick action
mesh services list                 # every mesh-owned daemon + active/enabled badges
mesh services status mysql         # one service's two bits + backend model
mesh services start  mysql redis   # start now (active) — does not change boot state
mesh services stop   mysql         # stop now — leaves its boot state untouched
mesh services enable  redis        # start at boot (enabled) — does not start it now
mesh services disable mysql        # stop starting at boot — leaves it running now
mesh services reconcile            # apply this host's services.default.<alias> boot-state
mesh services list --all           # also list discovered (non-curated) units, read-only
```

`mesh services` with no args opens the interactive flow; with no node/blink it
falls back to a `/dev/tty` bash picker. Names match by exact id, else substring
of the id or its aliases; a multi-service verb exits non-zero if **any** fails.

## The two-bit model (the crux)

Most tools conflate two states this command keeps separate:

- **active** — running right now → `start` / `stop` / `restart`
- **enabled** — comes up at boot/login → `enable` / `disable`

The pain it removes: keep a DB **installed** but **disabled** (no boot cost, no
idle RAM), then `mesh services start mysql` only when a project needs it. List
badges read `running`/`stopped` (active) × `on-boot`/`no-boot` (enabled).

## Backends — one interface, honest about coarseness

| Backend | Where | Orthogonal? | Model |
|---|---|---|---|
| **systemd** | WSL / Linux | yes | system scope via `sudo systemctl`; user scope via `systemctl --user` (+ linger), no sudo. enable/disable = boot-only, start/stop = runtime-only. |
| **brew services** | mac | **no** | `start`→`brew services run` (active only); `enable`→`brew services start` (also runs — there is no enable-without-run); `stop`→both bits. |
| **launchd** | mac | yes | non-brew mac daemons. |

On a **non-orthogonal** backend (brew) a verb that cannot preserve the
unrequested bit says so in `status`; the runner **never silently mutates the bit
you did not ask for** — and `reconcile` (enabled-bit only) **skips** a
non-orthogonal backend entirely rather than start/stop a running unit.

On a WSL host without systemd as PID 1, the systemd backend's `systemctl` calls
fail with a clear error — there is no automatic fallback. Enable systemd in WSL
(`/etc/wsl.conf` → `[boot]` `systemd=true`, then `wsl --shutdown`) to use
`mesh services` there.

## `--all` discovery is read-only

`mesh services list --all` (and the TUI `--all` mode) also surface every
systemd unit (WSL) / brew+launchd service (mac) **beyond** the curated registry.
Discovered entries carry no descriptor (no normalized kind/scope/target), so
mutating verbs are **refused** on them — only `list`/`status`. To make a
discovered service mutable, give it a descriptor module (below).

## php-fpm enumerates per installed version

`php-fpm` expands to one row per installed version — `php-fpm@8.2` …
`php-fpm@8.5` (WSL: glob `/etc/php/*/fpm`; mac: `brew list` → `php@<ver>`) — so
stopping one version leaves the others untouched.

## Install ≠ auto-enable

A fresh `mesh install` leaves each curated **opt-out** daemon (on WSL: `mysql`,
`redis`, `php-fpm`, `postgres`, `docker`) **installed but disabled at boot**
unless the host opts it in. Topic installers register the service via the shared
services lib instead of an inline `systemctl enable --now`.

The desired boot-state is per-host data in **mesh-identity**:
`config/services.default.<alias>` — one service id per line, `#` and blank lines
ignored (same shape as the `shell/*.list` files). A missing file means the empty
set, i.e. every opt-out daemon stays disabled at boot (the safe audit default).

```sh
# config/services.default.crc  — enable these at boot on the host `crc`
redis
php-fpm@8.4
```

`mesh services reconcile` (run directly, or by `mesh update`) flips this host's
enabled-set to match its `services.default.<alias>`: **enable/disable only,
idempotent, and it never stops a running unit** (systemd `disable` ≠ stop). So
reconcile reclaims a running daemon's RAM only at next boot or via an explicit
`mesh services stop`.

## Across the mesh

```sh
mesh run --all services status mysql    # report mysql's state on every host
mesh run --all services stop mysql      # stop it everywhere (allowlisted subverbs only)
```

The fan-out runs non-interactively and allowlists the read/write subverbs
(`status`/`start`/`stop`/`restart`/`enable`/`disable`); out-of-scope subverbs are
rejected.

## Adding a service

The registry is modular — one descriptor module per logical service under
[`scripts/lib/services/registry/`](../scripts/lib/services/registry/), mirroring
`scripts/lib/cleaners/`. The id comes from the filename (hyphens → underscores in
the function names). Drop in `<id>.sh` defining:

```sh
svcdef_<id>_meta()   { echo "Display name|alias1,alias2|owning-topic"; }
svcdef_<id>_wsl()    { echo "systemd|system|<unit>"; }   # or systemd|user|<unit>
svcdef_<id>_mac()    { echo "brew||<formula>"; }         # or launchd||<label>
svcdef_<id>_optout() { echo "wsl"; }                     # optional: OS tokens opt-out at boot
# svcdef_<id>_enumerate <os> { … }                       # optional: dynamic rows (see php-fpm)
```

`linux` falls back to the `wsl`/systemd mapping when no `svcdef_<id>_linux`
exists. The aggregator (`registry.sh`) walks `registry/*.sh`, skips
`_`-prefixed files, resolves for the current OS (override with
`MESH_SERVICES_OS`), and emits one machine-readable row per applicable service —
no central list to edit.

## See also

- [`docs/CLEAN.md`](CLEAN.md) — `mesh clean`, the sibling registry-driven command.
- `scripts/lib/services/` — drivers (`systemd`/`brew`/`launchd`) + registry.
- `mesh services -h` — the same verbs from the command line.
