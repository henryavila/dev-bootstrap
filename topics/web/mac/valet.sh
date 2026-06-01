#!/usr/bin/env bash
# Custom: Laravel Valet — composer global install + valet install + .localhost TLD + park CODE_DIR.

VALET_BIN="$HOME/.composer/vendor/bin/valet"
: "${CODE_DIR:=$HOME/code/web}"

check() {
    [[ -x "$VALET_BIN" ]] || return 1
    [[ -d "$HOME/.config/valet" ]] || return 1
    # TLD must be localhost. Read from config.json instead of `valet tld`,
    # because the CLI invokes sudo internally — the menu scanner stubs
    # sudo, so any `valet <cmd>` produces no output and fakes "not installed".
    local cfg="$HOME/.config/valet/config.json"
    [[ -f "$cfg" ]] || return 1
    grep -q '"tld"[[:space:]]*:[[:space:]]*"localhost"' "$cfg"
}

install() {
    if [[ ! -x "$VALET_BIN" ]]; then
        composer global require laravel/valet --no-interaction --quiet
    fi
    [[ -x "$VALET_BIN" ]] || { echo "[valet] composer install failed" >&2; return 1; }

    mkdir -p "$CODE_DIR"

    if [[ "${FORCE_VALET_INSTALL:-0}" == "1" ]]; then
        "$VALET_BIN" install || true
    elif [[ ! -d "$HOME/.config/valet" ]] || ! "$VALET_BIN" --version >/dev/null 2>&1; then
        "$VALET_BIN" install || true
    else
        echo "[valet] skipping valet install (already configured — set FORCE_VALET_INSTALL=1 to re-run)"
    fi

    # Refresh sudo cache (`valet tld` and `valet park` will sudo).
    sudo -v 2>/dev/null || true

    # Align TLD with WSL — .localhost is RFC 6761 browser-native.
    local current_tld
    current_tld="$("$VALET_BIN" tld 2>/dev/null | tr -d '\r' || true)"
    if [[ "$current_tld" != "localhost" ]]; then
        printf 'y\n' | "$VALET_BIN" tld localhost \
            || echo "[valet] tld localhost failed — sites may still resolve on .test" >&2
    fi

    ( cd "$CODE_DIR" && "$VALET_BIN" park ) || true
}

verify() {
    check
}

rollback() {
    # Don't auto-uninstall Valet — extensive system state.
    :
}
