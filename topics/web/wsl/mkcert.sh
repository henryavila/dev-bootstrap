#!/usr/bin/env bash
# Custom: mkcert + wildcard cert + Windows trust store import.

CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
WILDCARD_PEM="$CERT_DIR/wildcard-localhost.pem"
WILDCARD_KEY="$CERT_DIR/wildcard-localhost-key.pem"

check() {
    # `test -f` only needs stat() on the file path, which requires +x on
    # every parent dir but NOT read on the file itself. /etc/nginx/certs/
    # is created mode 0755 by `mkdir -p` (default umask), so the test
    # works as any user even though wildcard-localhost-key.pem is mode
    # 0640 root:root. Keeping check() sudo-free lets the menu scanner
    # probe state with zero password friction.
    command -v mkcert >/dev/null 2>&1 || return 1
    test -f "$WILDCARD_PEM" || return 1
    test -f "$WILDCARD_KEY" || return 1
    # Content sentinel: the rootCA that `mkcert -install` creates and that
    # signed the wildcard above MUST exist, else the certs are present but
    # untrusted (NSS/Windows browsers reject *.localhost) — a half-installed
    # state the bare file-existence checks above would falsely KEEP. CAROOT
    # is a per-user dir (~/.local/share/mkcert), so this stays sudo-free.
    # Guard against an empty CAROOT (mkcert error) collapsing to /rootCA.pem.
    local caroot
    caroot="$(mkcert -CAROOT 2>/dev/null)" || return 1
    [[ -n "$caroot" ]] || return 1
    test -f "$caroot/rootCA.pem" || return 1
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
    # This block is load-bearing for verify()=check() (asserts both PEMs
    # exist). Guard each step and return 1 on real failure so the engine
    # reports a clean 'mkcert install failed' instead of a confusing rc67
    # post-verify abort that masks the real cause.
    sudo mkdir -p "$CERT_DIR"
    if ! sudo test -f "$WILDCARD_PEM" || ! sudo test -f "$WILDCARD_KEY"; then
        local tmp
        tmp="$(mktemp -d)"
        if ! ( cd "$tmp" && mkcert \
            -cert-file "wildcard-localhost.pem" \
            -key-file  "wildcard-localhost-key.pem" \
            "*.localhost" "localhost" "*.front.localhost" "127.0.0.1" "::1" ); then
            echo "[mkcert] wildcard cert generation failed" >&2
            rm -rf "$tmp"
            return 1
        fi
        if ! sudo install -m 0644 -o root -g root "$tmp/wildcard-localhost.pem"     "$WILDCARD_PEM" \
           || ! sudo install -m 0640 -o root -g root "$tmp/wildcard-localhost-key.pem" "$WILDCARD_KEY"; then
            echo "[mkcert] failed to install wildcard cert into $CERT_DIR" >&2
            rm -rf "$tmp"
            return 1
        fi
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
            # Wrap in `timeout 45` — interop call can block indefinitely
            # if binfmt_misc is half-registered, /mnt/c is in I/O-error
            # state, or a hidden UAC prompt is up on the Windows side.
            # shellcheck disable=SC2016
            timeout --kill-after=5 45 \
                "$pwsh" -NoProfile -ExecutionPolicy Bypass -Command \
                "\$env:ROOTCA_PATH = '$rootca_win'; & '$ps_win'" 2>&1 \
                | sed 's/^/    /' \
                || echo "[mkcert] interop import failed (or hit 45s timeout) — run scripts/import-mkcert-from-windows.ps1 from Windows" >&2
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
