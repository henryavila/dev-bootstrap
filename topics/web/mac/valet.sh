#!/usr/bin/env bash
# Custom: Laravel Valet — composer global install + valet install + .localhost TLD + park CODE_DIR.

: "${CODE_DIR:=$HOME/code/web}"

# Resolve the valet binary from composer's actual global bin-dir at runtime.
# Composer's home is ~/.composer on older defaults but ~/.config/composer when
# XDG is set or on newer composer — never hard-pin one. Each verb is sourced in
# a fresh subshell, so this runs per verb.
_resolve_valet_bin() {
    local bindir cand
    bindir="$(composer global config --absolute bin-dir 2>/dev/null || true)"
    for cand in "$bindir/valet" \
                "$HOME/.composer/vendor/bin/valet" \
                "$HOME/.config/composer/vendor/bin/valet"; do
        if [[ -n "$cand" && -x "$cand" ]]; then
            VALET_BIN="$cand"
            return 0
        fi
    done
    # Not yet installed: default to composer's reported bin-dir if known,
    # else the legacy ~/.composer path so install() can write/probe it.
    VALET_BIN="${bindir:+$bindir/valet}"
    VALET_BIN="${VALET_BIN:-$HOME/.composer/vendor/bin/valet}"
    return 0
}

check() {
    _resolve_valet_bin
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
    _resolve_valet_bin
    if [[ ! -x "$VALET_BIN" ]]; then
        composer global require laravel/valet --no-interaction --quiet
        _resolve_valet_bin   # bin-dir now populated — re-resolve
    fi
    [[ -x "$VALET_BIN" ]] || { echo "[valet] composer install failed" >&2; return 1; }

    mkdir -p "$CODE_DIR"

    # `valet install` is load-bearing: it creates ~/.config/valet, which
    # post-verify check() asserts. A swallowed failure here re-surfaces as a
    # confusing rc67 whole-run abort, so capture its rc and fail cleanly.
    local need_install=0
    if [[ "${FORCE_VALET_INSTALL:-0}" == "1" ]]; then
        need_install=1
    elif [[ ! -d "$HOME/.config/valet" ]] || ! "$VALET_BIN" --version >/dev/null 2>&1; then
        need_install=1
    else
        echo "[valet] skipping valet install (already configured — set FORCE_VALET_INSTALL=1 to re-run)"
    fi
    if [[ "$need_install" == "1" ]]; then
        if ! "$VALET_BIN" install; then
            echo "[valet] valet install failed" >&2
            return 1
        fi
    fi

    # Refresh sudo cache (`valet tld` and `valet park` will sudo).
    sudo -v 2>/dev/null || true

    # Align TLD with WSL — .localhost is RFC 6761 browser-native. check()
    # asserts the configured tld is localhost, so a real failure here must
    # surface as install-failed, not a downstream verify abort.
    local current_tld
    current_tld="$("$VALET_BIN" tld 2>/dev/null | tr -d '\r' || true)"
    if [[ "$current_tld" != "localhost" ]]; then
        if ! printf 'y\n' | "$VALET_BIN" tld localhost; then
            echo "[valet] tld localhost failed — sites may still resolve on .test" >&2
            return 1
        fi
    fi

    # Parking is best-effort — check() does not assert it.
    ( cd "$CODE_DIR" && "$VALET_BIN" park ) || true
}

verify() {
    check
}

rollback() {
    # Don't auto-uninstall Valet — extensive system state.
    :
}
