# 60-laravel-stack (opt-in)

Enabled via `INCLUDE_LARAVEL=1 bash bootstrap.sh` (or by checking it in the interactive menu).

## What you get

| Component | WSL | macOS |
|---|---|---|
| MySQL 8 | apt `mysql-server-8.0` | brew `mysql@8.0` (+ Oracle DMG fallback auto-detected) |
| Redis | apt | brew |
| nginx | apt + Debian `sites-available` / `sites-enabled` convention | handled by Valet |
| PHP (multi-version) | apt `php{VER}` + `php{VER}-fpm` + extensions per version | brew `php@{VER}` (keg-only; default is the only linked one) |
| mkcert | GitHub release | brew (Valet uses it too) |
| Wildcard HTTPS cert | `*.localhost` + `localhost` + `*.front.localhost`, deployed once | per-site via `valet secure` |
| Catchall nginx site (`*.localhost` → PHP) | yes (template) | Valet serves parked dir |
| Catchall nginx proxy (`*.front.localhost` → :port) | yes (template) | `valet proxy` |
| `link-project` CLI | yes (wraps nginx) | yes (wraps Valet) — same commands, different backend |
| `share-project` CLI (ngrok) | opt-in | opt-in |
| mailpit (mail catcher) | opt-in | opt-in (brew) |
| ngrok | opt-in | opt-in (brew cask) |
| Microsoft SQL Server driver | opt-in (apt + PECL) | opt-in (brew tap + PECL — manual for now) |

## Multi-PHP

PHP versions are driven by a single source of truth: `topics/10-languages/data/php-versions.conf`.

```
8.2
8.3
8.4
8.5
```

When a new version releases (8.6, 9.0…), **adding one line there** is all the installer, menu, and nginx templates need. No other code changes.

The interactive menu lets you pick which versions to install (Screen 3c). The last selected wins as the **default** (`PHP_DEFAULT`) — the one that:

- `php` on `PATH` resolves to
- Composer runs under
- The nginx PHP catchall (`*.localhost`) points at (`/run/php/php${PHP_DEFAULT}-fpm.sock`)

Switch the default anytime with:

```bash
php-use 8.4    # Linux: update-alternatives; Mac: brew unlink/link
php-use --list # show installed versions + current default
```

**Non-automation**: to override from env vars (CI, scripted install):

```bash
PHP_VERSIONS="8.4 8.5" PHP_DEFAULT=8.5 \
  INCLUDE_LARAVEL=1 bash bootstrap.sh --non-interactive
```

## Extensions

Every PHP version gets the same baseline. Lists live at:

- `topics/10-languages/data/php-extensions-apt.txt` — apt packages (`php{VER}-bcmath` etc.), 17 today
- `topics/10-languages/data/php-extensions-pecl.txt` — PECL builds (igbinary, imagick, mongodb, redis), ABI-matched per version
- `topics/10-languages/data/php-extensions-mssql.txt` — opt-in (sqlsrv + pdo_sqlsrv)

To add a new apt extension: append a line (e.g. `gmp` → `php8.4-gmp`). To add a PECL extension with build deps: `myext:linux-deps:mac-deps`.

## HTTPS that works — including from Windows browsers

The WSL installer:

1. Runs `mkcert -install` (creates rootCA inside WSL + registers in NSS + system trust store).
2. Generates a wildcard cert covering `*.localhost`, `localhost`, `*.front.localhost`, `127.0.0.1`, `::1` — once, in `/etc/nginx/certs/wildcard-localhost.pem`.
3. **Imports the rootCA into the Windows user's certificate store** (`HKCU:\Root`) via a PowerShell script invoked over WSL interop. This is what makes `https://foo.localhost` green-padlocked in Chrome/Edge running on Windows — the browsers there consult the Windows store, not WSL's.

**Firefox users** on Windows: set `security.enterprise_roots.enabled = true` in `about:config`. Firefox reads the Windows store only when that flag is on.

## The two catchalls

| Host pattern | Backend | Use case |
|---|---|---|
| `https://<name>.localhost/` | PHP-FPM, doc root `$CODE_DIR/<name>/public/` | Laravel, PHP projects |
| `https://<name>.front.localhost/` | Reverse proxy to `127.0.0.1:$DEV_DEFAULT_PORT` (default 3000) | Nuxt / Vite / Next dev server |

Per-project port overrides:

```bash
link-project --frontend admin --port 5173    # vite default
link-project --frontend docs  --port 3001
```

Writes a dedicated `sites-available/proxy-<name>.conf` + symlink in `sites-enabled/`, reloads nginx.

## Reverse-proxy defaults (what gets included automatically)

The `snippets/dev-bootstrap-proxy.conf` that every proxy site pulls in:

- `upstream` with **keepalive pool** (32 conns, 60s timeout, 1000 requests) — reuses TCP across HMR.
- Full forwarding headers: `Host`, `X-Real-IP`, `X-Forwarded-For/Proto/Host/Port`, `Upgrade`, `Connection`.
- Timeouts: `connect 10s`, `send 60s`, `read 3600s` — SSE / long-poll / LLM streaming all survive.
- `proxy_buffering off` + `proxy_request_buffering off` — HMR + SSE reach the browser live.
- `error_page 502/503/504` with a styled inline HTML telling you how to start the dev server.

## Custom nginx sites you add yourself

`dev-bootstrap` only owns two files in `sites-available/`: `catchall-php.conf` and `catchall-proxy.conf`. Any other `.conf` you drop there — with no `managed by dev-bootstrap` header — is **never touched** by the bootstrap. `deploy.sh` refuses to overwrite unmanaged files.

Typical flow for a custom site:

```bash
sudo tee /etc/nginx/sites-available/my-thing.conf <<EOF
server {
    listen 80; listen 443 ssl http2;
    server_name my-thing.example.dev;
    ssl_certificate     /etc/nginx/certs/my-cert.pem;
    ssl_certificate_key /etc/nginx/certs/my-cert-key.pem;
    # ... your stuff ...
}
EOF
sudo ln -s /etc/nginx/sites-available/my-thing.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
```

Re-running `bash bootstrap.sh` is safe — `my-thing.conf` stays put.

## Optional extras

### mailpit (mail catcher)

Opt-in via menu or `INCLUDE_MAILPIT=1`. SMTP on `127.0.0.1:1025`, web UI on `127.0.0.1:8025`.

Laravel `.env` snippet:

```
MAIL_MAILER=smtp
MAIL_HOST=127.0.0.1
MAIL_PORT=1025
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_ENCRYPTION=null
```

### ngrok (public tunnel)

Opt-in via menu or `INCLUDE_NGROK=1`. Needs a free authtoken from ngrok.com — either pass it via `NGROK_AUTHTOKEN=` during bootstrap, or run `ngrok config add-authtoken <token>` later.

```bash
share-project foo               # tunnels https://foo.localhost (via nginx catchall)
share-project foo --port 3000   # bypass nginx, tunnel http://localhost:3000 directly
```

### Microsoft SQL Server driver

Opt-in via menu or `INCLUDE_MSSQL=1`. **WSL/Linux only for now** — Mac still requires manual `brew tap microsoft/mssql-release` + PECL step (the Linux script is documented well enough to port later).

Installs:

1. Microsoft APT repo + modern keyring (`/etc/apt/keyrings/microsoft.gpg`)
2. `msodbcsql18` + `mssql-tools18` + `unixodbc-dev` (ACCEPT_EULA=Y auto-set — Microsoft requires explicit consent, we log a warning)
3. `pecl install sqlsrv pdo_sqlsrv` for **every** PHP version in `PHP_VERSIONS` (each rebuild is ABI-matched to its PHP).
4. Enables both extensions via `phpenmod`.

**Connection string (corporate SQL Servers with self-signed certs)**:

```
Server=tcp:host,1433;Database=db;Encrypt=yes;TrustServerCertificate=yes
```

msodbcsql18 requires TLS 1.2+ — `TrustServerCertificate=yes` is the Microsoft-documented escape hatch for self-signed deployments.

## macOS notes

The Mac installer delegates nginx + HTTPS + DNS to **Laravel Valet**:

```bash
composer global require laravel/valet
valet install                          # sets up nginx + dnsmasq + mkcert
valet tld localhost                    # align TLD with WSL (default is .test)
valet park $CODE_DIR                   # every subdir becomes <name>.localhost
```

The `valet tld localhost` step is important: URLs work identically on WSL and Mac (`https://foo.localhost`) — your muscle memory doesn't switch based on the platform. `link-project` on Mac is a thin wrapper around `valet secure` + `valet proxy`. Same command name, different backend.

Oracle MySQL DMG: if `/usr/local/mysql/bin/mysql` exists, the installer **skips** `brew install mysql@8.0` entirely. No double-install conflict.

## Quick reference

```bash
# Start services after a reboot (Linux / WSL — systemd)
sudo systemctl start mysql redis nginx php${PHP_DEFAULT}-fpm

# Mac (brew services + Valet)
brew services start mysql@8.0 redis mailpit
# (nginx is handled by Valet)

# Link a Laravel site
link-project foo                        # → https://foo.localhost

# Register a frontend dev server
link-project --frontend admin --port 5173   # → https://admin.front.localhost

# Switch PHP default
php-use 8.4

# Tunnel publicly
share-project foo                       # ngrok on https://foo.localhost

# List what's enabled
link-project --list
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `NET::ERR_CERT_AUTHORITY_INVALID` in Chrome/Edge on Windows | mkcert CA not imported into Windows store | Re-run `install.wsl.sh` — the PowerShell step will import if missing |
| Firefox keeps showing cert error | Firefox ignores Windows store by default | Set `security.enterprise_roots.enabled = true` in `about:config` |
| `php -m` doesn't show sqlsrv after MSSQL install | PECL build hit a missing `php{VER}-dev` header | `sudo apt install php{VER}-dev && sudo pecl install -f sqlsrv` |
| `*.localhost` works in browser but `curl foo.localhost` fails | curl linked against a libc that doesn't follow RFC 6761 (rare) | Add `127.0.0.1 foo.localhost` to `/etc/hosts` manually (only for that edge case) |
| nginx reload says `host not found in upstream` | `dev-bootstrap-maps.conf` missing from `conf.d/` | Re-run `bash bootstrap.sh` — `deploy.sh` will put it back |
