#!/usr/bin/env bash
# Custom: Laravel Valet — composer global install + valet install + .localhost TLD + park CODE_DIR.

: "${CODE_DIR:=$HOME/code}"

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

# Is CODE_DIR on an external /Volumes/<vol> that is NOT currently mounted?
# When true, valet has nothing to serve yet, so repair must DEFER: do not fail
# check(), and do NOT `mkdir -p` a phantom /Volumes/... on the root disk that
# would later collide with the real mount point (verify/operational plan D-3).
_valet_external_unmounted() {
    case "${CODE_DIR:-}" in
        /Volumes/*) ;;
        *) return 1 ;;                              # not on an external volume
    esac
    local rest vol
    rest="${CODE_DIR#/Volumes/}"
    vol="${rest%%/*}"
    [[ -n "$vol" ]] || return 1
    # Mounted iff `mount` lists "... on /Volumes/<vol> (". A leftover/phantom
    # directory is NOT a mount, so this distinguishes "volume present" from it.
    mount 2>/dev/null | grep -qF " on /Volumes/$vol (" && return 1
    return 0                                        # configured external path, not mounted
}

# Sudo-free operational probe: are all three valet daemons actually serving?
# The valet CLI shells out to sudo (and the menu scanner stubs sudo), so we
# probe the live stack directly instead of asking the CLI — TCP for nginx, a
# direct dnsmasq query for DNS, and the php-fpm socket. Any miss ⇒ stack down.
_valet_stack_ok() {
    # nginx listening on :80 (bash /dev/tcp; the subshell closes the fd on exit)
    (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null || return 1
    # dnsmasq answers *.localhost on 127.0.0.1. Require a real answer, not just
    # rc 0 — dscacheutil returns 0 with NO records (plan §2.5). `dig` is bundled
    # on macOS and queries dnsmasq's loopback :53 directly, bypassing the system
    # resolver. valet with tld=localhost registers /etc/resolver/localhost + a
    # dnsmasq zone, so a healthy stack returns the loopback address.
    local ans
    ans="$(dig @127.0.0.1 probe.localhost +time=1 +tries=1 +short 2>/dev/null)"
    [[ "$ans" == "127.0.0.1" || "$ans" == "::1" ]] || return 1
    # php-fpm up: the valet.sock symlink target exists.
    [[ -e "$HOME/.config/valet/valet.sock" ]] || return 1
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
    grep -q '"tld"[[:space:]]*:[[:space:]]*"localhost"' "$cfg" || return 1
    # External parked volume unmounted → nothing to serve; DEFER (treat as OK so
    # the engine does not trigger a repair that would mkdir a phantom path).
    if _valet_external_unmounted; then
        echo "[valet] CODE_DIR ($CODE_DIR) on an unmounted external volume — deferring stack probe" >&2
        return 0
    fi
    # Operational: the serving stack must actually be up. Previously check() was
    # config-marker only, so it returned 0 (engine KEEP) while every daemon was
    # down — the audit's live critical. This makes check() operational, sudo-free.
    _valet_stack_ok
}

install() {
    _resolve_valet_bin
    if [[ ! -x "$VALET_BIN" ]]; then
        composer global require laravel/valet --no-interaction --quiet
        _resolve_valet_bin   # bin-dir now populated — re-resolve
    fi
    [[ -x "$VALET_BIN" ]] || { echo "[valet] composer install failed" >&2; return 1; }

    # External parked volume unmounted → DEFER: do not `mkdir -p` a phantom path
    # nor run valet install against a volume that isn't there (plan D-3). Repairs
    # and normal runs both skip cleanly until the volume is back.
    if _valet_external_unmounted; then
        echo "[valet] CODE_DIR ($CODE_DIR) on an unmounted external volume — skipping install/park (deferred)" >&2
        return 0
    fi

    mkdir -p "$CODE_DIR"

    # `valet install` is load-bearing: it creates ~/.config/valet, which
    # post-verify check() asserts. A swallowed failure here re-surfaces as a
    # confusing rc67 whole-run abort, so capture its rc and fail cleanly.
    local need_install=0
    if [[ "${FORCE_VALET_INSTALL:-0}" == "1" ]]; then
        need_install=1
    elif [[ ! -d "$HOME/.config/valet" ]] || ! "$VALET_BIN" --version >/dev/null 2>&1; then
        need_install=1
    elif ! _valet_stack_ok; then
        # Config present and the CLI works, but the serving stack is DOWN. The
        # old conditions stopped here (valet --version succeeds → skip), so a
        # rebooted machine with stopped daemons silently kept a dead valet. Now
        # we re-run `valet install` to re-register & start nginx/dnsmasq/php-fpm.
        echo "[valet] serving stack down (nginx/dnsmasq/php-fpm) — re-running valet install" >&2
        need_install=1
    else
        echo "[valet] skipping valet install (already configured & serving — set FORCE_VALET_INSTALL=1 to re-run)"
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

repair() {
    # Engine --repair sweep: force the serving stack back up THROUGH the
    # installer (governing principle §0 — no manual `valet restart`). FORCE makes
    # install() re-run `valet install` even when config markers look fine;
    # install() still defers on an unmounted external volume.
    FORCE_VALET_INSTALL=1 install
}

rollback() {
    # Don't auto-uninstall Valet — extensive system state.
    :
}
