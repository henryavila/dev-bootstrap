#!/usr/bin/env bash
# install-mssql-driver.sh — Microsoft SQL Server ODBC driver + PHP
# extensions (sqlsrv, pdo_sqlsrv). Opt-in piece of 60-web-stack,
# gated by INCLUDE_MSSQL=1.
#
# What this script does (idempotent top to bottom):
#   1. Adds the Microsoft APT repo via the modern keyring pattern
#      (/etc/apt/keyrings/microsoft.gpg), not the deprecated apt-key.
#   2. Installs msodbcsql18 (ODBC driver), mssql-tools18 (sqlcmd/bcp),
#      and unixodbc-dev (headers needed to compile the PECL extensions).
#      ACCEPT_EULA=Y is auto-set — Microsoft requires explicit accept
#      but we log a warning so the user sees what's happening.
#   3. For every PHP version in $PHP_VERSIONS, `pecl install` sqlsrv +
#      pdo_sqlsrv bound to that version's phpize (ABI-specific .so).
#   4. Enables the extensions via phpenmod for both CLI and FPM.
#
# Connection string note (document once in the 60-web-stack README):
#   msodbcsql18 requires TLS 1.2+. Self-signed certs (common in corporate
#   SQL Servers) need the connection string to include:
#       Encrypt=yes;TrustServerCertificate=yes

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../lib/log.sh"

# ─── OS check ─────────────────────────────────────────────────────────
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    warn "install-mssql-driver.sh is Ubuntu/Debian-only. Mac users: brew tap microsoft/mssql-release && brew install msodbcsql18 mssql-tools18"
    exit 0
fi

# ─── Microsoft APT repo + keyring ────────────────────────────────────
KEYRING="/etc/apt/keyrings/microsoft.gpg"
SOURCES_LIST="/etc/apt/sources.list.d/mssql-release.list"

if [[ ! -f "$KEYRING" ]]; then
    info "adding Microsoft GPG keyring"
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | sudo gpg --dearmor -o "$KEYRING"
fi

if [[ ! -f "$SOURCES_LIST" ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release     # provides VERSION_ID (e.g. "24.04") + VERSION_CODENAME
    info "adding Microsoft SQL Server APT source for Ubuntu $VERSION_ID"
    echo "deb [arch=amd64 signed-by=$KEYRING] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod $VERSION_CODENAME main" \
        | sudo tee "$SOURCES_LIST" > /dev/null
    sudo apt-get update -qq
fi

# ─── Install driver + tools ──────────────────────────────────────────
warn "Microsoft ODBC driver EULA auto-accepted (ACCEPT_EULA=Y)"
warn "  licence: https://aka.ms/odbc18eula"

pkgs=(msodbcsql18 mssql-tools18 unixodbc-dev)
missing=()
for p in "${pkgs[@]}"; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        missing+=("$p")
    fi
done
if [[ "${#missing[@]}" -gt 0 ]]; then
    info "installing: ${missing[*]}"
    sudo ACCEPT_EULA=Y apt-get install -y -qq "${missing[@]}"
fi

# Add sqlcmd + bcp to PATH via a login-shell profile snippet (once)
PROFILE_SNIPPET="/etc/profile.d/mssql-tools.sh"
if [[ ! -f "$PROFILE_SNIPPET" ]]; then
    echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' \
        | sudo tee "$PROFILE_SNIPPET" > /dev/null
    sudo chmod 0644 "$PROFILE_SNIPPET"
    ok "sqlcmd / bcp added to PATH via $PROFILE_SNIPPET"
fi

# ─── PECL: sqlsrv + pdo_sqlsrv per PHP version ───────────────────────
# PHP_VERSIONS is set by the bootstrap pipeline. If empty, bail — this
# script doesn't try to guess.
PHP_VERSIONS_TO_PATCH="${PHP_VERSIONS:-${PHP_DEFAULT:-}}"
if [[ -z "$PHP_VERSIONS_TO_PATCH" ]]; then
    warn "neither PHP_VERSIONS nor PHP_DEFAULT set — skipping PECL install"
    exit 0
fi

install_mssql_ext() {
    local ver="$1" ext="$2"
    local pecl_bin="/usr/bin/pecl${ver}"
    [[ ! -x "$pecl_bin" ]] && pecl_bin="$(command -v pecl || true)"
    [[ -z "$pecl_bin" ]] && { warn "no pecl binary for PHP $ver"; return; }

    if "php${ver}" -m 2>/dev/null | grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$"; then
        ok "PHP $ver: $ext already loaded"
        return 0
    fi

    info "PHP $ver: pecl install $ext"
    # -f forces rebuild if a previous broken build is cached
    printf '\n' | sudo "$pecl_bin" install -f "$ext" >/dev/null 2>&1 || {
        warn "PHP $ver: pecl install $ext failed — SQL Server support won't work on this PHP"
        return 0
    }

    local ini_file="/etc/php/${ver}/mods-available/${ext}.ini"
    if [[ ! -f "$ini_file" ]]; then
        echo "extension=${ext}.so" | sudo tee "$ini_file" > /dev/null
    fi
    sudo phpenmod -v "$ver" "$ext" >/dev/null 2>&1 || true
    ok "PHP $ver: $ext enabled"
}

for ver in $PHP_VERSIONS_TO_PATCH; do
    # php${ver}-dev already installed by 10-languages for PECL builds;
    # verify defensively so a standalone run of this script still works.
    if ! dpkg -s "php${ver}-dev" >/dev/null 2>&1; then
        info "installing php${ver}-dev (required for PECL build)"
        sudo apt-get install -y -qq "php${ver}-dev"
    fi

    install_mssql_ext "$ver" sqlsrv
    install_mssql_ext "$ver" pdo_sqlsrv
done

# Restart FPMs so the extensions are picked up without manual kick
for ver in $PHP_VERSIONS_TO_PATCH; do
    if systemctl is-active --quiet "php${ver}-fpm" 2>/dev/null; then
        sudo systemctl restart "php${ver}-fpm" \
            && ok "restarted php${ver}-fpm"
    fi
done

ok "MSSQL driver + sqlsrv/pdo_sqlsrv ready for: $PHP_VERSIONS_TO_PATCH"
ok "  connect string (self-signed corporate servers):"
ok "    Server=tcp:host,1433;Database=db;Encrypt=yes;TrustServerCertificate=yes"
