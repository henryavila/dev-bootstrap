#!/usr/bin/env bash
# 00-core (mac): install Homebrew (canonical or custom prefix) + minimal tooling.
#
# Brew prefix decision ladder (highest priority first):
#   1. Already installed on disk — `lib/detect-brew.sh` finds the binary →
#      use that prefix, persist in state.env (method=detected_existing).
#   2. State file has a previously-recorded BREW_PREFIX from an earlier run,
#      and the binary at that path doesn't exist (user nuked it manually) —
#      install fresh at the recorded prefix (method=state_replay).
#   3. `BREW_CUSTOM_PREFIX` env var is set — install there (method=env_var).
#   4. Interactive TTY — prompt with default = /opt/homebrew, allow custom
#      path entry (method=prompt).
#   5. Non-interactive context — silent default /opt/homebrew + warn that
#      the user can override on next run via env var (method=default).
#
# Canonical prefix (/opt/homebrew, /usr/local) → use the official Homebrew
# installer (which ignores --prefix and lands in the canonical location anyway).
# Custom prefix → bootstrap via direct git clone of Homebrew/brew, since the
# official installer refuses non-canonical prefixes.
#
# After installing, the user's choice is persisted via state.env so this
# whole ladder is skipped on subsequent runs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../lib/state.sh"

# ----------------------------------------------------------------------
# Helpers — prefix decision + custom install
# ----------------------------------------------------------------------

# Emit a structural warning enumerating the implications of a custom
# Homebrew prefix. Sources of cumulative tech debt are referenced by their
# decision IDs in dotfiles/.ai/memory/PROJECT_STATUS.md §5.
#
# In TTY: prints the warning and prompts y/N. Returns 0 on yes / 1 on no.
# Non-TTY: prints the warning and returns 0 (proceeds without blocking —
# CI / scripted runs can't answer prompts; logged warn is the audit trail).
emit_custom_prefix_warning() {
    local prefix="$1"
    cat >&2 <<EOF

  ╭───────────────────────────────────────────────────────────────────╮
  │  Custom Homebrew prefix selected: $prefix
  │
  │  This is a fully supported choice, but it carries cumulative
  │  trade-offs that the canonical /opt/homebrew prefix avoids:
  │
  │    • Bottles do not relocate → most installs build from source
  │      (D31 — \`brew_install_if_missing\` 3-tier retry pattern).
  │    • Non-interactive shells (sshd-exec, launchd) won't see the
  │      prefix in PATH unless /etc/paths.d/60-extbrew is injected
  │      (D32 — handled in topics/70-remote-access).
  │    • brew-php in custom prefix doesn't symlink \`extension_dir\`
  │      (D34 — PECL 3-path reconciliation in topics/10-languages).
  │    • LaunchDaemons that log to \$BREW_PREFIX/var/log/* trigger a
  │      phantom-mkdir race on first boot if the volume is external
  │      (D42 — PlistBuddy hardening in topics/60-web-stack).
  │    • User-scope LaunchAgents (mailpit/redis/postgres@17/syncthing)
  │      hit the TCC sandbox and exit 78 — all wrapped via rootfs
  │      shims by lib/launch-wrapper.sh in their topics.
  │
  │  All of the above are AUTOMATED by dev-bootstrap; you don't need
  │  to do anything manually. The note exists so you understand why
  │  re-runs in this prefix take longer (source builds) than they
  │  would in /opt/homebrew.
  ╰───────────────────────────────────────────────────────────────────╯

EOF
    if [[ -t 0 ]] && [[ -t 1 ]] && [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
        local reply=""
        printf '  Continue with prefix %s? [y/N] ' "$prefix" >&2
        # `read -r` from /dev/tty so we don't get fooled by stdin redirects;
        # a default empty answer => no.
        if ! read -r reply </dev/tty 2>/dev/null; then
            warn "  prompt blocked (no controlling tty?) — assuming 'no'"
            return 1
        fi
        case "$reply" in
            y|Y|yes|YES) return 0 ;;
            *)           return 1 ;;
        esac
    fi
    # Non-interactive: log and proceed
    info "non-interactive context — proceeding with custom prefix without prompt"
    return 0
}

# Untar-anywhere install of Homebrew. The official curl|bash installer
# ignores --prefix and lands in /opt/homebrew or /usr/local; for any
# other location we have to bootstrap brew the way the docs describe in
# the "Untar anywhere" section: clone the brew repo into the prefix dir
# directly, then prime its caches via `brew update --force --quiet`.
install_brew_at_custom_prefix() {
    local prefix="$1"
    local parent
    parent="$(dirname "$prefix")"

    if [[ -e "$prefix" ]] && [[ -n "$(ls -A "$prefix" 2>/dev/null || true)" ]]; then
        fail "refusing to install brew at $prefix — directory exists and is non-empty"
        fail "  remove it manually or pick a different prefix"
        return 1
    fi

    info "creating prefix directory: $prefix"
    if ! mkdir -p "$prefix" 2>/dev/null; then
        # User likely lacks write permission on parent; try sudo + chown.
        info "  parent dir $parent needs sudo to create $prefix"
        sudo mkdir -p "$prefix"
        sudo chown "$USER:$(id -gn)" "$prefix"
    fi

    info "git clone https://github.com/Homebrew/brew.git → $prefix"
    git clone --depth=1 https://github.com/Homebrew/brew.git "$prefix"

    # Prime caches so the next `brew install` doesn't trigger a
    # bottle-list refresh in the middle of unrelated work.
    info "brew update --force --quiet"
    "$prefix/bin/brew" update --force --quiet || warn "brew update returned non-zero (formula cache may be cold; will recover on first install)"

    # zsh completion dir must not be group-writable or compinit refuses it.
    if [[ -d "$prefix/share/zsh" ]]; then
        chmod -R go-w "$prefix/share/zsh" 2>/dev/null || true
    fi
}

# Decide where Homebrew should live. Prints the chosen prefix to stdout
# and assigns the decision method to global var $BREW_DECISION_METHOD as
# a side effect (for caller logging + state.env recording).
#
# Honors the ladder documented at the top of this file.
decide_brew_prefix() {
    BREW_DECISION_METHOD=""

    # 1. Already installed on disk — detect-brew.sh wins.
    local out
    if out="$(bash "$HERE/../../lib/detect-brew.sh" 2>/dev/null)"; then
        eval "$out"
        BREW_DECISION_METHOD="detected_existing"
        printf '%s' "$BREW_PREFIX"
        return 0
    fi

    # 2. State file has a recorded BREW_PREFIX (user chose this on a previous run)
    local recorded
    if recorded="$(state_get BREW_PREFIX 2>/dev/null)" && [[ -n "$recorded" ]]; then
        BREW_DECISION_METHOD="state_replay"
        printf '%s' "$recorded"
        return 0
    fi

    # 3. BREW_CUSTOM_PREFIX env var
    if [[ -n "${BREW_CUSTOM_PREFIX:-}" ]]; then
        BREW_DECISION_METHOD="env_var"
        printf '%s' "$BREW_CUSTOM_PREFIX"
        return 0
    fi

    # 4. Interactive TTY → prompt
    if [[ -t 0 ]] && [[ -t 1 ]] && [[ "${NON_INTERACTIVE:-0}" != "1" ]]; then
        local reply=""
        # Print prompt to stderr so stdout stays clean for capture
        cat >&2 <<EOF

  Where should Homebrew live?

    Default:   /opt/homebrew  (canonical, recommended — bottles work,
                              zero workarounds)
    Custom:    any absolute path (e.g. /Volumes/External/homebrew if
                              you keep dev tooling on a separate SSD).
                              See bottle-less trade-offs warning below.

EOF
        printf '  prefix [/opt/homebrew]: ' >&2
        if read -r reply </dev/tty 2>/dev/null; then
            if [[ -z "$reply" ]]; then
                BREW_DECISION_METHOD="prompt"
                printf '/opt/homebrew'
                return 0
            fi
            BREW_DECISION_METHOD="prompt"
            printf '%s' "$reply"
            return 0
        fi
    fi

    # 5. Non-interactive default
    BREW_DECISION_METHOD="default"
    warn "non-interactive context — defaulting to /opt/homebrew"
    warn "  (set BREW_CUSTOM_PREFIX=/path/to/brew to override on next run)"
    printf '/opt/homebrew'
    return 0
}

# ----------------------------------------------------------------------
# Main flow
# ----------------------------------------------------------------------

# Decide the prefix BEFORE attempting to install. The decision function
# also detects "brew already installed" and short-circuits.
chosen_prefix="$(decide_brew_prefix)"

case "$chosen_prefix" in
    /opt/homebrew|/usr/local)
        is_canonical=1
        ;;
    *)
        is_canonical=0
        ;;
esac

if [[ "$BREW_DECISION_METHOD" == "detected_existing" ]]; then
    ok "brew ready at $BREW_BIN (prefix $chosen_prefix; previously installed)"
    state_record_brew_prefix "$chosen_prefix" "detected_existing"
elif [[ "$BREW_DECISION_METHOD" == "state_replay" ]]; then
    info "state.env recorded brew prefix $chosen_prefix on a previous run; reinstalling"
    if [[ "$is_canonical" == "1" ]]; then
        info "installing Homebrew (canonical prefix — official installer)"
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    else
        emit_custom_prefix_warning "$chosen_prefix" || {
            fail "user declined re-install at $chosen_prefix — abort"
            fail "  to change the recorded prefix, edit $(state_path) or set BREW_CUSTOM_PREFIX"
            exit 1
        }
        install_brew_at_custom_prefix "$chosen_prefix"
    fi
    # Re-detect after install
    if out=$(bash "$HERE/../../lib/detect-brew.sh"); then
        eval "$out"
    else
        fail "brew install completed but detect-brew.sh still cannot find it"
        exit 1
    fi
    state_record_brew_prefix "$BREW_PREFIX" "state_replay"
elif [[ "$is_canonical" == "1" ]]; then
    info "installing Homebrew at $chosen_prefix (canonical — official installer)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if out=$(bash "$HERE/../../lib/detect-brew.sh"); then
        eval "$out"
    else
        fail "brew install completed but detect-brew.sh still cannot find it"
        exit 1
    fi
    state_record_brew_prefix "$BREW_PREFIX" "$BREW_DECISION_METHOD"
else
    info "installing Homebrew at $chosen_prefix (custom prefix — git clone)"
    if ! emit_custom_prefix_warning "$chosen_prefix"; then
        fail "user declined custom prefix — abort"
        fail "  to retry, re-run without BREW_CUSTOM_PREFIX (default = /opt/homebrew)"
        exit 1
    fi
    install_brew_at_custom_prefix "$chosen_prefix"
    BREW_BIN="$chosen_prefix/bin/brew"
    BREW_PREFIX="$chosen_prefix"
    export BREW_BIN BREW_PREFIX
    state_record_brew_prefix "$BREW_PREFIX" "$BREW_DECISION_METHOD"
fi

ok "brew ready at $BREW_BIN"

pkgs=(
    git
    curl
    wget
    gnupg
    jq
    unzip
    gettext
)

for p in "${pkgs[@]}"; do
    if "$BREW_BIN" list --formula "$p" >/dev/null 2>&1; then
        ok "$p already installed"
    else
        info "brew install $p"
        "$BREW_BIN" install "$p"
    fi
done

# gettext is keg-only on macOS; envsubst must be reachable via PATH.
envsubst_path="$BREW_PREFIX/opt/gettext/bin/envsubst"
if [[ -x "$envsubst_path" ]] && ! command -v envsubst >/dev/null 2>&1; then
    warn "envsubst installed but not in PATH; add $BREW_PREFIX/opt/gettext/bin to PATH"
    warn "topic 30-shell handles this via bashrc.d/zshrc.d fragments"
fi

ok "00-core done"
