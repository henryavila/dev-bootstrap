# 60-laravel-stack (opt-in)

Enabled via `INCLUDE_LARAVEL=1 bash bootstrap.sh` (or by checking it in the interactive menu).

**Installs:** MySQL 8, Redis, Nginx, PHP-FPM 8.4 (WSL) / Nginx + PHP via `10-languages` (Mac), mkcert.

**Deploys (via `DEPLOY` file):**
- `nginx-catchall.conf` — serves `*.localhost` → `$CODE_DIR/<project>/public`. `$CODE_DIR` and the FPM socket path are expanded via `envsubst`.
- `~/.local/bin/link-project` — CLI helper: `link-project foo` → adds a `foo.localhost` hosts entry (WSL) and warns if `public/` is missing.

**Env vars:** `CODE_DIR` (default `~/code/web`, editable in the menu), `BREW_PREFIX` (Mac), `NGINX_CONF_DIR` (derived by `install.$OS.sh`).

## MySQL 8

- **WSL**: `mysql-server-8.0` package, pinned explicitly — not the meta `mysql-server`, which can resolve to MariaDB on some Debian derivatives.
- **Mac**: Homebrew `mysql@8.0` formula (keg-only → the installer runs `brew link --force --overwrite mysql@8.0` to put `mysql`/`mysqladmin` on `$PATH`).

### Mac troubleshooting: `brew install mysql@8.0` failing

If brew can't install/run MySQL (permissions, conflict with a prior install, etc.), the fallback is Oracle's official DMG:

1. Download from https://dev.mysql.com/downloads/mysql/ (DMG Archive).
2. Run the installer — it drops binaries in `/usr/local/mysql/bin/`.
3. The bootstrap auto-detects `/usr/local/mysql/bin/mysql` and skips the brew install in that case.
4. Add `/usr/local/mysql/bin` to your `PATH` if it isn't already (the Oracle installer usually does this — verify with `command -v mysql`).

**Post-install:** on WSL, start the services manually:
```
sudo systemctl start mysql redis nginx php8.4-fpm
```
On Mac, `brew services` has already been invoked by the installer.
