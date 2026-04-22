# 45-docker — Docker Engine (opt-in)

Opt-in topic. Disabled by default. Enable with `INCLUDE_DOCKER=1` or the
interactive menu checkbox.

## What installs

### WSL / Linux

- `docker.io` — Ubuntu's packaged Docker Engine (not `docker-ce`). Boring
  choice: no extra apt repo, no PPA, no signing-key maintenance. Fine for
  dev work; production deployments should follow the official docker-ce docs.
- `docker-compose-v2` — Compose plugin (`docker compose ...` syntax).
- Adds `$USER` to the `docker` group so `docker` runs without sudo.
  Takes effect on next login, or run `newgrp docker` immediately.
- If systemd is available (`/etc/wsl.conf` with `[boot] systemd=true`),
  enables and starts `docker.service` so the daemon comes up on every
  boot. Non-systemd WSL: start manually with `sudo service docker start`.

### macOS

- **Colima** — headless Linux VM via `lima`. Chosen over Docker Desktop
  because it's free, open-source, no GUI, no forced login, no aggressive
  auto-updater. Runs as a regular CLI daemon.
- `docker` — the CLI (formula), pointed at Colima's socket automatically
  once `colima start` runs.
- `docker-compose` — the standalone v2 binary (works with Colima).

**Not started automatically.** The Colima VM consumes ~2 GB RAM idle, so
it's not a good citizen for always-on. Start when needed:

```bash
colima start       # brings VM + Docker daemon up (~30 s first time)
docker ps          # should work now
colima stop        # reclaim RAM when done
```

`colima status` shows the current state. The VM is persistent — `start`
after `stop` reuses the same VM, no rebuild.

## When to enable

- You develop projects that ship Dockerfiles or `docker-compose.yml`.
- You run the local smoke test in `dev-bootstrap/ci/smoke-test.sh` (builds
  a fresh Ubuntu container).
- You use dev containers in VS Code.
- You want to isolate experiments (try a database server, an LLM inference
  tool, etc.) without polluting the host.

## When NOT to enable

- You don't use containers. Keep the topic off — 300 MB+ of disk, a
  daemon, a group membership change, and on Mac 2 GB RAM whenever the VM
  is up. All waste if unused.
- Corporate-policy machines where container runtimes are restricted.

## Verify

`verify.sh` checks the CLI is present and the Compose subcommand works
(either the `docker-compose` binary or the `docker compose` plugin).
It deliberately does **not** run `docker info` — the daemon being down
is a normal state (Colima stopped, `service docker stop` on WSL), not
a verification failure.

## Uninstall / disable

Setting `INCLUDE_DOCKER=0` on future runs won't remove what's already
installed. To roll back:

```bash
# WSL
sudo apt-get remove --purge docker.io docker-compose-v2
sudo deluser "$USER" docker

# Mac
colima stop && colima delete
brew uninstall colima docker docker-compose
```
