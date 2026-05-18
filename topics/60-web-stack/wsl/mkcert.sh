#!/usr/bin/env bash
# Custom: mkcert + wildcard cert + Windows trust store import.

CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
WILDCARD_PEM="$CERT_DIR/wildcard-localhost.pem"
WILDCARD_KEY="$CERT_DIR/wildcard-localhost-key.pem"

check() {
    command -v mkcert >/dev/null 2>&1 || return 1
    sudo test -f "$WILDCARD_PEM" || return 1
    sudo test -f "$WILDCARD_KEY" || return 1
    return 0
}

install() {
    sudo -v 2>/dev/null || true
    export DEBIAN_FRONTEND=noninteractive

    # Install mkcert binary if missing.
    if ! command -v mkcert >/dev/null 2>&1; then
        sudo apt-get install -y -q libnss3-tools
        local ver tmp
        ver="$(curl -fsSL https://api.github.com/repos/FiloSottile/mkcert/releases/latest | jq -r '.tag_name')"
        tmp="$(mktemp -d)"
        curl -fsSL -o "$tmp/mkcert" \
            "https://github.com/FiloSottile/mkcert/releases/download/${ver}/mkcert-${ver}-linux-amd64"
        sudo install -m 0755 "$tmp/mkcert" /usr/local/bin/mkcert
        rm -rf "$tmp"
    fi

    # Install rootCA into WSL trust stores.
    mkcert -install \
        || echo "[mkcert] mkcert -install had issues — Firefox profile may need a TTY" >&2

    # Generate wildcard cert if missing.
    sudo mkdir -p "$CERT_DIR"
    if ! sudo test -f "$WILDCARD_PEM" || ! sudo test -f "$WILDCARD_KEY"; then
        local tmp
        tmp="$(mktemp -d)"
        ( cd "$tmp" && mkcert \
            -cert-file "wildcard-localhost.pem" \
            -key-file  "wildcard-localhost-key.pem" \
            "*.localhost" "localhost" "*.front.localhost" "127.0.0.1" "::1" )
        sudo install -m 0644 -o root -g root "$tmp/wildcard-localhost.pem"     "$WILDCARD_PEM"
        sudo install -m 0640 -o root -g root "$tmp/wildcard-localhost-key.pem" "$WILDCARD_KEY"
        rm -rf "$tmp"
    fi

    # Windows trust import — best-effort with Lane B fallback noted on failure.
    local rootca pwsh
    rootca="$(mkcert -CAROOT)/rootCA.pem"
    pwsh=""
    for cand in powershell.exe pwsh.exe \
                "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
                "/mnt/c/Program Files/PowerShell/7/pwsh.exe"; do
        if command -v "$cand" >/dev/null 2>&1 || [[ -x "$cand" ]]; then
            pwsh="$cand"; break
        fi
    done

    if [[ ! -f "$rootca" ]]; then
        echo "[mkcert] rootCA missing at $rootca — Windows browsers will distrust *.localhost" >&2
        echo "[mkcert] retry: rerun this topic after 'mkcert -CAROOT' shows a directory" >&2
    elif [[ -n "$pwsh" ]]; then
        local here ps_win rootca_win
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if wslpath -w "$rootca" >/dev/null 2>&1; then
            rootca_win="$(wslpath -w "$rootca")"
            ps_win="$(wslpath -w "$here/../scripts/import-mkcert-windows.ps1")"
            # shellcheck disable=SC2016
            "$pwsh" -NoProfile -ExecutionPolicy Bypass -Command \
                "\$env:ROOTCA_PATH = '$rootca_win'; & '$ps_win'" 2>&1 \
                | sed 's/^/    /' \
                || echo "[mkcert] interop import failed — run scripts/import-mkcert-from-windows.ps1 from Windows" >&2
        else
            echo "[mkcert] wslpath -w failed — run scripts/import-mkcert-from-windows.ps1 from Windows side" >&2
        fi
    else
        echo "[mkcert] powershell.exe unreachable — run scripts/import-mkcert-from-windows.ps1 from Windows side" >&2
    fi
}

verify() {
    check
}

rollback() {
    # Cert state has system-wide effects; don't auto-uninstall.
    :
}
