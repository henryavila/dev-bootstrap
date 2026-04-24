#!/usr/bin/env bash
# 60-web-stack (WSL): MySQL 8, Redis, nginx + mkcert (wildcard) + optional
# extras (mailpit, ngrok, SQL Server driver). HTTPS works end-to-end
# from WSL to the Windows host's browsers via automatic rootCA import.
#
# nginx topology:
#   /etc/nginx/sites-available/catchall-php.conf    → *.localhost  (PHP-FPM)
#   /etc/nginx/sites-available/catchall-proxy.conf  → *.front.localhost (reverse proxy)
#   /etc/nginx/snippets/dev-bootstrap-*.conf        → shared includes
#   /etc/nginx/conf.d/dev-bootstrap-maps.conf       → http{} level maps
#   /etc/nginx/certs/wildcard-localhost.pem         → cert for *.localhost
#                                                     + localhost + *.front.localhost
#
# install.sh deploys the files and then creates sites-enabled symlinks,
# respecting the Debian convention (user can `unlink` to disable a site
# without losing the config).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

# ─── Sudo keepalive + non-interactive apt ────────────────────────────
# Earlier topics (00-core brew install, 10-languages multi-PHP + PECL) can
# run well past the sudo cache window (default 5-15min). Without a refresh
# here, the first sudo call downstream would silently block waiting for a
# password prompt that may be lost to `-qq` / `2>/dev/null` silencers — the
# classic "terminal hangs, ENTER sometimes asks for password" UX.
#
# `sudo -v` re-prompts once UP-FRONT with stdin/stderr unobstructed, then
# every subsequent sudo inside this script runs without prompting until the
# cache expires again. If the user has passwordless sudo this is a no-op.
#
# DEBIAN_FRONTEND=noninteractive + -o Dpkg::Options are the standard pair
# that keep apt from ever bringing up an interactive curses dialog (service
# restart during upgrade, sshd config merge, …). They have to be exported
# so child apt-get invocations inherit them.
info "this topic provisions the web stack — may take 30-120s on first run"
if ! sudo -v; then
    warn "sudo validate failed — individual steps will re-prompt if needed"
fi
export DEBIAN_FRONTEND=noninteractive
APT_NONINTERACTIVE_FLAGS=(-y -q
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold")

# ─── nginx paths (exported for deploy.sh envsubst) ───────────────────
export NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
export NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
export NGINX_SNIPPET_DIR="/etc/nginx/snippets"
export NGINX_MAP_DIR="/etc/nginx/conf.d"
export CERT_DIR="/etc/nginx/certs"
# Legacy compat (still used by lib/deploy.sh ENVSUBST_ALLOWLIST defaults)
export NGINX_CONF_DIR="$NGINX_ENABLED_DIR"

# ─── CODE_DIR + DEV_DEFAULT_PORT ─────────────────────────────────────
: "${CODE_DIR:=$HOME/code/web}"
: "${DEV_DEFAULT_PORT:=3000}"
export CODE_DIR DEV_DEFAULT_PORT
mkdir -p "$CODE_DIR"

# ─── PHP_DEFAULT (from 10-languages) ─────────────────────────────────
# PHP_DEFAULT is set by 10-languages from PHP_VERSIONS. Fall back to whatever
# /usr/bin/php resolves to if this topic runs standalone (ONLY_TOPICS).
if [[ -z "${PHP_DEFAULT:-}" ]]; then
    if command -v php >/dev/null 2>&1; then
        PHP_DEFAULT="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
        info "PHP_DEFAULT inferred from current default: $PHP_DEFAULT"
    else
        fail "PHP_DEFAULT not set and no php on PATH — run 10-languages first"
        exit 1
    fi
fi
export PHP_DEFAULT

# ─── Base packages ───────────────────────────────────────────────────
# Explicit mysql-server-8.0 (not meta mysql-server → can resolve to MariaDB
# on some Debian-derived distros).
pkgs=(mysql-server-8.0 redis-server nginx)
missing=()
for p in "${pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        missing+=("$p")
    fi
done
if [[ "${#missing[@]}" -gt 0 ]]; then
    info "installing: ${missing[*]} (apt; mysql-server can take 30-60s on first run)"
    sudo apt-get update -q
    sudo apt-get install "${APT_NONINTERACTIVE_FLAGS[@]}" "${missing[@]}"
fi

# PHP-FPM for every installed version (each FPM runs independently, socket
# per version under /run/php/). Default catchall points at PHP_DEFAULT; users
# with one project needing an older PHP can create a dedicated site config.
for ver in ${PHP_VERSIONS:-$PHP_DEFAULT}; do
    if ! dpkg -s "php${ver}-fpm" >/dev/null 2>&1; then
        info "installing php${ver}-fpm"
        sudo apt-get install "${APT_NONINTERACTIVE_FLAGS[@]}" "php${ver}-fpm"
    fi
done

# ─── mkcert + wildcard cert ──────────────────────────────────────────
if ! command -v mkcert >/dev/null 2>&1; then
    info "installing mkcert"
    sudo apt-get install "${APT_NONINTERACTIVE_FLAGS[@]}" libnss3-tools
    mkcert_ver="$(curl -fsSL https://api.github.com/repos/FiloSottile/mkcert/releases/latest | jq -r '.tag_name')"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/mkcert" "https://github.com/FiloSottile/mkcert/releases/download/${mkcert_ver}/mkcert-${mkcert_ver}-linux-amd64"
    sudo install -m 0755 "$tmp/mkcert" /usr/local/bin/mkcert
    rm -rf "$tmp"
else
    ok "mkcert already installed"
fi

# Install rootCA into WSL trust stores (NSS + system). `mkcert -install`
# shells out to `sudo` when it needs to write /usr/local/share/ca-certificates.
# We DO NOT silence stderr here — if the sudo cache expired between topics,
# the user needs to see the password prompt, not a frozen terminal.
info "installing mkcert rootCA into WSL trust stores (may prompt for sudo)"
mkcert -install || warn "mkcert -install had issues — re-run inside a TTY for Firefox profile"

# Generate wildcard cert covering BOTH catchall subdomains in one file
sudo mkdir -p "$CERT_DIR"
WILDCARD_PEM="$CERT_DIR/wildcard-localhost.pem"
WILDCARD_KEY="$CERT_DIR/wildcard-localhost-key.pem"
if [[ ! -f "$WILDCARD_PEM" ]] || [[ ! -f "$WILDCARD_KEY" ]]; then
    info "generating wildcard localhost cert (mkcert)"
    tmp="$(mktemp -d)"
    ( cd "$tmp" && mkcert \
        -cert-file "wildcard-localhost.pem" \
        -key-file  "wildcard-localhost-key.pem" \
        "*.localhost" "localhost" "*.front.localhost" "127.0.0.1" "::1" )
    sudo install -m 0644 -o root -g root "$tmp/wildcard-localhost.pem"     "$WILDCARD_PEM"
    sudo install -m 0640 -o root -g root "$tmp/wildcard-localhost-key.pem" "$WILDCARD_KEY"
    rm -rf "$tmp"
    ok "wildcard cert → $WILDCARD_PEM"
else
    ok "wildcard cert already exists"
fi

# ─── Windows trust store import (so Chrome/Edge on Windows trust us) ──
# WSL-only path. Runs the PowerShell script on the Windows side via
# interop, imports rootCA into HKCU:\Root (user scope, no admin).
#
# `command -v powershell.exe` fails when /etc/wsl.conf has
# [interop] appendWindowsPath=false — the binary exists but isn't on
# $PATH. Fall through to absolute paths before giving up.
PWSH_BIN=""
for cand in powershell.exe pwsh.exe \
            "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
            "/mnt/c/Program Files/PowerShell/7/pwsh.exe"; do
    if command -v "$cand" >/dev/null 2>&1; then
        PWSH_BIN="$cand"; break
    fi
    if [[ -x "$cand" ]]; then
        PWSH_BIN="$cand"; break
    fi
done

# ─── Two-lane import: interop-first, Windows-side fallback ───────────
# Lane A (fast path): invoke import-mkcert-windows.ps1 via powershell.exe
#   called FROM inside WSL. Depends on binfmt_misc/WSLInterop being
#   registered — see scripts/diagnose-wsl-interop.sh for when it's not.
#
# Lane B (fallback, robust): when Lane A doesn't work, emit instructions
#   to run import-mkcert-from-windows.ps1 FROM Windows PowerShell. That
#   second script uses `wsl.exe cat` which goes through the VM host
#   channel — a DIFFERENT communication path that survives the
#   "/mnt/c is I/O error + binfmt_misc unregistered" state of the
#   interop layer.
#
# We always emit Lane B instructions as a `followup critical` when
# Lane A fails, so the user has a working path regardless of the root
# cause of the interop breakage.

ROOTCA="$(mkcert -CAROOT)/rootCA.pem"
PS_SCRIPT_IN="$HERE/scripts/import-mkcert-windows.ps1"
PS_SCRIPT_OUT="$HERE/scripts/import-mkcert-from-windows.ps1"

# Build the Windows-side UNC path pointing at the from-windows script.
# Uses \\wsl.localhost\<distro>\<linux-path> which Windows resolves via
# its own 9P server (SMB/WSL bridge) — independent of WSL interop.
_DETECTED_DISTRO="${WSL_DISTRO_NAME:-$(lsb_release -si 2>/dev/null || echo Ubuntu)}"
_PS_UNC_PATH="\\\\wsl.localhost\\${_DETECTED_DISTRO}${PS_SCRIPT_OUT//\//\\}"

_emit_lane_b_followup() {
    local reason="$1"
    followup critical \
"Windows CA import via WSL interop FAILED: $reason
Effect: HTTPS *.localhost will fail with ERR_CERT_AUTHORITY_INVALID in
        Chrome/Edge on the Windows host. (Firefox + curl inside WSL
        still work — the WSL trust store is fine.)

SOLUTION (robust, independent of WSL interop):

  Open Windows PowerShell (on the Windows side, NOT inside WSL), then run:

    powershell -ExecutionPolicy Bypass -File '$_PS_UNC_PATH'

  -ExecutionPolicy Bypass is scoped to THIS invocation only — needed
  because PowerShell refuses unsigned scripts over UNC paths by
  default. The script auto-detects the WSL distro + user; if that
  fails, the error message prints the exact retry command with
  -Distro '${_DETECTED_DISTRO}' pre-filled.

  The script reads the rootCA from WSL via 'wsl.exe cat' (VM host
  channel) and imports into HKCU:\\Root. No admin needed. Idempotent.

Also valid (optional — only if you prefer to fix the interop instead):
  - Diagnose:  bash $HERE/scripts/diagnose-wsl-interop.sh
  - First-aid: 'wsl --shutdown' from Windows, reopen WSL, re-run
               bootstrap.  This doesn't prevent recurrence — the
               PowerShell fallback above is the path that always works."
}

if [[ ! -f "$ROOTCA" ]]; then
    _emit_lane_b_followup "mkcert rootCA.pem missing at $ROOTCA"
elif [[ -n "$PWSH_BIN" ]]; then
    # Lane A — interop available. Try the direct import.
    #
    # We wrap the powershell.exe invocation in `timeout 45` as a safety
    # net: a broken interop layer (binfmt_misc half-registered, /mnt/c in
    # I/O-error state, Windows side showing a hidden UAC prompt) can make
    # the call block indefinitely with no output. 45s is well above any
    # legitimate run-time (import is a few hundred ms) and below a
    # threshold where the user gives up. Exit 124 from `timeout` means
    # "killed for exceeding the deadline" — we route that into the Lane B
    # followup just like any other failure mode.
    info "importing mkcert rootCA into Windows CurrentUser\\Root (via interop; ≤45s)"
    if wslpath -w "$ROOTCA" >/dev/null 2>&1; then
        ROOTCA_WIN="$(wslpath -w "$ROOTCA")"
        PS_WIN="$(wslpath -w "$PS_SCRIPT_IN")"
        # shellcheck disable=SC2016  # the $env: is PowerShell-side, not bash
        if timeout --kill-after=5 45 \
                "$PWSH_BIN" -NoProfile -ExecutionPolicy Bypass -Command \
                "\$env:ROOTCA_PATH = '$ROOTCA_WIN'; & '$PS_WIN'" \
                2>&1 | sed 's/^/    /'; then
            ok "Windows CA import succeeded via interop"
        else
            rc=${PIPESTATUS[0]}
            if [[ "$rc" == "124" || "$rc" == "137" ]]; then
                _emit_lane_b_followup "interop call exceeded 45s timeout (rc=$rc; likely binfmt_misc/9P stall)"
            else
                _emit_lane_b_followup "interop invocation returned non-zero (rc=$rc)"
            fi
        fi
    else
        _emit_lane_b_followup "wslpath -w failed (drvfs mapping broken)"
    fi
else
    # Lane A unavailable — go straight to Lane B instructions.
    _emit_lane_b_followup "powershell.exe not reachable from WSL (binfmt_misc/interop broken)"
fi

# ─── Optional extras: mailpit, ngrok, MSSQL driver ───────────────────
# Each gated by its own INCLUDE_* env var. Script paths are siblings of
# this installer so they can be invoked standalone too.
if [[ "${INCLUDE_MAILPIT:-0}" == "1" ]] && [[ -x "$HERE/scripts/install-mailpit.sh" ]]; then
    info "installing mailpit (SMTP :1025, UI :8025)"
    bash "$HERE/scripts/install-mailpit.sh" || warn "mailpit install failed (non-fatal)"
fi

if [[ "${INCLUDE_NGROK:-0}" == "1" ]] && [[ -x "$HERE/scripts/install-ngrok.sh" ]]; then
    info "installing ngrok"
    bash "$HERE/scripts/install-ngrok.sh" || warn "ngrok install failed (non-fatal)"
fi

if [[ "${INCLUDE_MSSQL:-0}" == "1" ]] && [[ -x "$HERE/scripts/install-mssql-driver.sh" ]]; then
    info "installing Microsoft SQL Server driver + PHP extensions"
    bash "$HERE/scripts/install-mssql-driver.sh" || warn "MSSQL driver install failed (non-fatal)"
fi

# ─── Nginx dirs + sites-enabled symlinks ─────────────────────────────
# deploy.sh already dropped files into NGINX_AVAILABLE_DIR. Create symlinks
# in NGINX_ENABLED_DIR so nginx loads them (Debian convention).
sudo mkdir -p "$NGINX_AVAILABLE_DIR" "$NGINX_ENABLED_DIR" "$NGINX_SNIPPET_DIR" "$NGINX_MAP_DIR"

# Cleanup: if the OLD single-file catchall.conf from pre-v2026-04-23 is
# still in sites-enabled as a regular file (not symlink), remove it so
# the new sites-available/catchall-php.conf + symlink doesn't conflict.
OLD_CATCHALL="$NGINX_ENABLED_DIR/catchall.conf"
if [[ -f "$OLD_CATCHALL" ]] && [[ ! -L "$OLD_CATCHALL" ]]; then
    if grep -qi "managed by dev-bootstrap" "$OLD_CATCHALL" 2>/dev/null; then
        info "removing legacy $OLD_CATCHALL (replaced by split sites)"
        sudo rm -f "$OLD_CATCHALL"
    fi
fi

# Create/refresh symlinks for our managed sites
for site in catchall-php.conf catchall-proxy.conf; do
    src="$NGINX_AVAILABLE_DIR/$site"
    dst="$NGINX_ENABLED_DIR/$site"
    [[ ! -f "$src" ]] && continue
    if [[ ! -L "$dst" ]] || [[ "$(readlink -f "$dst")" != "$(readlink -f "$src")" ]]; then
        sudo ln -sf "$src" "$dst"
        ok "enabled site: $site"
    else
        ok "$site already enabled"
    fi
done

# ─── Pre-flight: port :80 / :443 conflict detection ──────────────────
# Corporate / pre-provisioned machines (and any host where Apache shipped
# in the base image) frequently have apache2 already bound to :80. apt
# happily installs nginx alongside Apache — the conflict only surfaces
# when systemd tries to start nginx and the bind() fails. Without an
# upfront check, the topic prints "couldn't reload nginx" once and exits 0;
# the failure mode (nginx in `failed` state for 22h, web stack non-functional)
# is invisible until the user later visits *.localhost and sees a connection
# refused. Detected on crc 2026-04-24.
#
# We use `ss -tlnp` (sudo for the -p column to show owner). If something
# other than nginx owns :80 we emit a `followup critical` with the exact
# disable command and set PORT_CONFLICT=1 to skip the reload below
# (avoids the misleading "could not reload" line on top of the real cause).
PORT_CONFLICT=""
if command -v ss >/dev/null 2>&1; then
    port80_owner="$(sudo ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print $NF}' | head -1)"
    if [[ -n "$port80_owner" ]] && [[ "$port80_owner" != *'"nginx"'* ]]; then
        # Extract the program name from ss's `users:(("apache2",pid=N,fd=M))` form
        owner_name="$(printf '%s' "$port80_owner" | sed -nE 's/.*\(\("([^"]+)".*/\1/p')"
        : "${owner_name:=unknown}"
        PORT_CONFLICT=1
        case "$owner_name" in
            apache2|apache|httpd)
                followup critical "port 80 is owned by $owner_name (not nginx) — disable it and start nginx with:
        sudo systemctl disable --now ${owner_name}
        sudo systemctl restart nginx"
                ;;
            *)
                followup critical "port 80 is owned by '$owner_name' (not nginx) — stop it (e.g. 'sudo systemctl disable --now ${owner_name}') then 'sudo systemctl restart nginx'"
                ;;
        esac
    fi
fi

# Validate config before suggesting reload — catches obvious breakage on first run
if [[ -n "$PORT_CONFLICT" ]]; then
    warn "skipping nginx reload — another service owns port 80 (see followup summary above)"
elif sudo nginx -t >/dev/null 2>&1; then
    ok "nginx config is valid"
    sudo systemctl reload nginx 2>/dev/null \
        || sudo service nginx reload 2>/dev/null \
        || warn "couldn't reload nginx (not running?) — start with: sudo systemctl start nginx"
else
    warn "nginx config FAILED validation — run 'sudo nginx -t' to see the error"
fi

ok "60-web-stack (wsl) done — default PHP: $PHP_DEFAULT"
ok "  start services once:   sudo systemctl start mysql redis nginx php${PHP_DEFAULT}-fpm"
ok "  create a Laravel site: link-project <name>          → https://<name>.localhost"
ok "  create a proxy site:   link-project --frontend <name> [--port 3000]  → https://<name>.front.localhost"
