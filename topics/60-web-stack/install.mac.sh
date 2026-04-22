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
    command -v mysql >/dev/null 2>&1 \
        || warn "/usr/local/mysql/bin not on PATH; add it to your shell rc"
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

# Don't silence stderr: mkcert shells out to `sudo security add-trusted-cert`
# on macOS to install the rootCA into the Keychain, and the sudo prompt
# MUST be visible for the user to type their password. Silencing here was
# the root cause of "terminal hangs, press Enter, sometimes asks for
# password" reports on older builds.
info "installing mkcert rootCA into macOS Keychain (may prompt for sudo)"
mkcert -install || warn "mkcert -install had issues — re-run in a TTY for Firefox profile"

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
    # `valet install` is idempotent — re-runs refresh nginx/dnsmasq config
    # but won't duplicate services or break existing parked dirs.
    info "valet install (nginx + dnsmasq + HTTPS setup)"
    "$VALET_BIN" install --quiet >/dev/null 2>&1 || warn "valet install returned non-zero"

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

ok "60-web-stack (mac) done — use link-project <name> to verify a site"
