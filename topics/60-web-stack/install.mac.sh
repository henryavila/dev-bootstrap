#!/usr/bin/env bash
# 60-web-stack (mac): MySQL 8, Redis, mkcert + Valet. Optional: mailpit,
# ngrok, SQL Server driver.
#
# Design: on macOS, Valet is Laravel-team-maintained and already solves nginx
# + dnsmasq + PHP switching + *.localhost resolution + HTTPS — everything our
# WSL installer reinvents by hand. We install MySQL/Redis/mkcert via brew
# (Valet doesn't manage them) and hand off the rest to Valet.
#
# TLD alignment: Valet defaults to `.test`, but we set it to `.localhost`
# via `valet tld localhost` so URLs match WSL exactly (foo.localhost works
# on both platforms; user muscle memory doesn't switch based on OS).
# `.localhost` is an RFC 6761 loopback TLD, natively handled by every
# browser + curl, no extra DNS resolution needed.
#
# User-facing CLIs stay the same: `link-project foo` works identically
# across platforms (on Mac it's a thin wrapper around `valet link +
# valet secure`; on WSL it touches sites-available and mkcert directly).

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"

: "${BREW_BIN:?BREW_BIN not set — run through bootstrap.sh}"
: "${BREW_PREFIX:?BREW_PREFIX not set}"

info "this topic provisions the web stack (MySQL + Redis + mkcert + Valet); may take 1-3min on first run"

# CODE_DIR is where Valet will `park` — every subdir becomes <name>.localhost
: "${CODE_DIR:=$HOME/code/web}"
mkdir -p "$CODE_DIR"
export CODE_DIR

# ─── MySQL 8 ───────────────────────────────────────────────────────
# Oracle DMG fallback: if /usr/local/mysql/bin/mysql exists, skip brew
# (double-install is always bad, Oracle's DMG installer is outside brew's
# management so uninstall is a manual step).
ORACLE_MYSQL_BIN="/usr/local/mysql/bin/mysql"
if [[ -x "$ORACLE_MYSQL_BIN" ]]; then
    info "Oracle MySQL detected at /usr/local/mysql — skipping brew install"
    # Auto-register the Oracle DMG bin/ in /etc/paths.d/ so `mysql` /
    # `mysqladmin` / `mysqldump` are on PATH for both interactive and
    # non-interactive shells (sshd-exec, hooks). Same mechanism we use
    # for non-standard BREW_PREFIX in 70-remote-access — path_helper
    # picks it up on every shell init via /etc/zprofile.
    paths_file="/etc/paths.d/61-oracle-mysql"
    if ! sudo grep -q "^/usr/local/mysql/bin$" "$paths_file" 2>/dev/null; then
        echo "/usr/local/mysql/bin" | sudo tee "$paths_file" >/dev/null
        ok "registered /usr/local/mysql/bin in $paths_file (path_helper picks up in new shells)"
    else
        ok "/usr/local/mysql/bin already in $paths_file"
    fi
else
    if "$BREW_BIN" list --formula mysql@8.0 >/dev/null 2>&1; then
        ok "mysql@8.0 already installed"
    else
        info "brew install mysql@8.0"
        "$BREW_BIN" install mysql@8.0
    fi
    # mysql@8.0 is keg-only; link so `mysql` / `mysqladmin` / `mysqldump` go on PATH
    "$BREW_BIN" link --force --overwrite mysql@8.0 >/dev/null 2>&1 \
        || warn "brew link mysql@8.0 failed — mysql may not be on PATH"
    info "starting mysql@8.0 via brew services"
    "$BREW_BIN" services start mysql@8.0 >/dev/null 2>&1 || true
fi

# ─── Redis + mkcert ────────────────────────────────────────────────
for p in redis mkcert; do
    if "$BREW_BIN" list --formula "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        info "brew install $p"
        "$BREW_BIN" install "$p"
    fi
done

# NOTE: we deliberately do NOT call `mkcert -install` on macOS.
# Valet's `valet install` (below) and `valet secure <site>` invoke mkcert
# themselves with the right scope (Keychain + Firefox NSS). Calling
# `mkcert -install` here would trigger a duplicate `security add-trusted-cert`
# prompt that the user has to authorize twice — and on cancel, leaves a
# misleading error in the log even though Valet handles it correctly later.
# Linux/WSL still calls mkcert -install in its install.wsl.sh because there
# we manage nginx + the trust store ourselves (no Valet equivalent).

info "starting redis via brew services"
"$BREW_BIN" services start redis >/dev/null 2>&1 || true

# ─── Laravel Valet (replaces manual nginx + dnsmasq) ─────────────────
# Installed via composer global; the binary ends up at
# ~/.composer/vendor/bin/valet. We ensure that dir is on PATH via a
# shell fragment (handled by 30-shell + the personal dotfiles), but
# invoke via absolute path here for robustness.
VALET_BIN="$HOME/.composer/vendor/bin/valet"
if [[ ! -x "$VALET_BIN" ]]; then
    info "composer global require laravel/valet"
    composer global require laravel/valet --no-interaction --quiet
fi

if [[ -x "$VALET_BIN" ]]; then
    # Valet install is idempotent in theory — but in practice it (a) prompts
    # for sudo to install nginx/dnsmasq services even when they're already
    # running, (b) re-runs `mkcert -install`, (c) takes 10-30s even when
    # everything is already in place. Skip when we can detect a healthy
    # pre-existing install:
    #   - Valet's config dir exists at ~/.config/valet
    #   - `valet --version` returns successfully
    # Both conditions met = stack is up; no need to re-install.
    if [[ -d "$HOME/.config/valet" ]] \
       && "$VALET_BIN" --version >/dev/null 2>&1; then
        ok "valet already installed and configured (skipping valet install)"
    else
        info "valet install (nginx + dnsmasq + HTTPS setup; first time only, ~30s)"
        "$VALET_BIN" install --quiet >/dev/null 2>&1 \
            || warn "valet install returned non-zero"
    fi

    # Align TLD with WSL — use `.localhost` instead of Valet's default `.test`
    # so URLs like https://foo.localhost work identically on both platforms.
    # Idempotent: `valet tld` is a no-op when the TLD already matches.
    current_tld="$("$VALET_BIN" tld 2>/dev/null | tr -d '\r' || true)"
    if [[ "$current_tld" != "localhost" ]]; then
        info "valet tld localhost (was: ${current_tld:-unknown})"
        "$VALET_BIN" tld localhost >/dev/null 2>&1 || warn "valet tld localhost failed — sites may still resolve on .test"
    else
        ok "valet tld already = localhost"
    fi

    # Park CODE_DIR so every subdirectory is served as <name>.localhost
    # Idempotent: Valet stores parks in ~/.config/valet/config.json
    info "valet park $CODE_DIR"
    ( cd "$CODE_DIR" && "$VALET_BIN" park --quiet >/dev/null 2>&1 ) || true

    ok "Valet ready — every dir under $CODE_DIR is https://<dir>.localhost"
else
    warn "valet binary not found after composer install — check composer config"
fi

# ─── Optional extras ────────────────────────────────────────────────
if [[ "${INCLUDE_MAILPIT:-0}" == "1" ]] && [[ -x "$HERE/scripts/install-mailpit.sh" ]]; then
    info "installing mailpit"
    bash "$HERE/scripts/install-mailpit.sh" || warn "mailpit install failed (non-fatal)"
fi

if [[ "${INCLUDE_NGROK:-0}" == "1" ]] && [[ -x "$HERE/scripts/install-ngrok.sh" ]]; then
    info "installing ngrok"
    bash "$HERE/scripts/install-ngrok.sh" || warn "ngrok install failed (non-fatal)"
fi

if [[ "${INCLUDE_MSSQL:-0}" == "1" ]]; then
    warn "MSSQL driver install on Mac uses brew tap microsoft/mssql-release"
    warn "  brew tap microsoft/mssql-release https://github.com/Microsoft/homebrew-mssql-release"
    warn "  brew install msodbcsql18 mssql-tools18"
    warn "  Then for each PHP version: pecl install sqlsrv pdo_sqlsrv"
    warn "  Automated install on Mac is a future enhancement."
fi

# ─── Pre-migrate legacy unmarked nginx files ────────────────────────
# deploy.sh refuses to overwrite files in $BREW_PREFIX/etc/nginx/ that
# don't carry the "managed by dev-bootstrap" marker — that's the safety
# rail protecting user-authored configs from silent overwrite. But on
# machines that ran an OLDER bootstrap (before the marker convention was
# added to these specific templates), the files exist on disk without
# the marker. They ARE ours, just from an earlier era.
#
# This block recognizes those exact paths and quarantines unmarked
# instances by renaming to <path>.pre-bootstrap-bak-<timestamp>. deploy.sh
# then writes the new version with the marker. Backup is preserved so
# the user can diff if curious; it is never auto-deleted.
#
# Limited to the 5 nginx files we actually deploy on Mac — nothing
# outside that allowlist is touched. The HOME/.local/bin CLIs
# (link-project, share-project) are user-owned and not migrated here.
LEGACY_FILES=(
    "$NGINX_SNIPPET_DIR/dev-bootstrap-security.conf"
    "$NGINX_SNIPPET_DIR/dev-bootstrap-proxy.conf"
    "$NGINX_MAP_DIR/dev-bootstrap-maps.conf"
    "$NGINX_AVAILABLE_DIR/catchall-php.conf"
    "$NGINX_AVAILABLE_DIR/catchall-proxy.conf"
)
_migration_ts="$(date +%Y%m%d-%H%M%S)"
for legacy in "${LEGACY_FILES[@]}"; do
    [[ -z "$legacy" ]] && continue
    if sudo test -f "$legacy" 2>/dev/null \
       && ! sudo grep -q "managed by dev-bootstrap" "$legacy" 2>/dev/null; then
        backup="${legacy}.pre-bootstrap-bak-${_migration_ts}"
        info "migrating legacy unmarked file: $legacy → $backup"
        sudo mv "$legacy" "$backup"
    fi
done
unset _migration_ts

ok "60-web-stack (mac) done — use link-project <name> to verify a site"
