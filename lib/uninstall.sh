#!/usr/bin/env bash
# lib/uninstall.sh — drift cleanup library for installed artifacts.
#
# Source this file from a topic's install.<suffix>.sh, then call
# uninstall_apply with the path to a manifest. The manifest lists
# artifacts the topic used to install but no longer does — every run
# of install.<suffix>.sh re-applies removals so machines already
# provisioned converge to the new desired state on the next bootstrap
# (or auto-update, which re-runs the affected install scripts).
#
# Why a generic library: install steps span 9 distinct verbs (apt, brew,
# brew-cask, clones, zinit plugins, user/system binaries, fonts) and a
# given product retirement may touch several of them at once (e.g.
# zsh-you-should-use lives in brew + ~/.local/share/ + zinit cache —
# 3 verbs, 1 product). Centralizing the verb→action mapping keeps each
# topic's manifest a flat declarative list.
#
# Companion mechanism: topics/50-git/data/gitconfig.removed handles
# `git config --unset` (key/value, not artifact removal). Different
# paradigm — kept separate intentionally.
#
# Usage:
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$HERE/../../lib/log.sh"
#   source "$HERE/../../lib/uninstall.sh"
#   …topic install logic…
#   uninstall_apply "$HERE/data/uninstall.list"
#
# Manifest format (one removal per line):
#   verb:arg
#
# Supported verbs:
#   apt:<package>            sudo apt-get purge   (Linux only; no-op on Mac)
#   brew:<formula>           brew uninstall       (Mac only;   no-op on Linux)
#   brew-cask:<cask>         brew uninstall --cask
#   font:<cask>              alias of brew-cask (semantic clarity for fonts)
#   clone:<dir-name>         rm -rf ~/.local/share/<dir-name>
#                              sandbox: refuses arg containing `/` or `..`
#   zinit:<owner>/<repo>     rm -rf ~/.local/share/zinit/plugins/<owner>---<repo>
#   user-bin:<name>          rm -f ~/.local/bin/<name>     (no slash, no ..)
#   sys-bin:<name>           sudo rm -f /usr/local/bin/<name>
#
# Limitations (out of scope, intentional):
#   - vendor curl|sh installers (fnm, tailscale, bun, claude): no generic
#     reverser; each vendor has its own uninstall flow. Add ad-hoc per case.
#   - line-level edits to /etc/wsl.conf, /etc/shells, etc.: needs sed-with-
#     marker or augeas-style tooling, not a flat manifest.
#   - jq merges into JSON config files: same as above.
#
# Idempotency: each handler is safe to call when the artifact is absent
# (silent no-op). Real failures (lock contention, sudo refused) emit a
# `warn` and continue — the install script never aborts because of a
# stale removal.
#
# Dependency policy (per project decision Q4 = always remove dependents):
#   - apt: `purge` + `autoremove -y` to clean orphaned deps
#   - brew: `--ignore-dependencies` (force-remove even if dependents exist)
#     The trade-off is that brew dependents may end up partially broken;
#     on this stack the items being removed are typically leaves (plugins,
#     CLIs) where this matters in practice. Revisit if a non-leaf removal
#     ever shows up.

# shellcheck shell=bash

# ─── Public entry point ──────────────────────────────────────────────
uninstall_apply() {
    local manifest="$1"
    [[ -f "$manifest" ]] || return 0   # absent manifest = nothing to do (valid)

    local line verb arg
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # Skip blank and comment lines
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Split verb:arg on the FIRST colon (args may legitimately contain
        # slashes, e.g. `zinit:owner/repo`). Refuse lines without a colon.
        if [[ "$line" != *:* ]]; then
            warn "uninstall.sh: malformed line (no verb:arg) — '$line'"
            continue
        fi
        verb="${line%%:*}"
        arg="${line#*:}"

        # Trim whitespace from both
        verb="${verb#"${verb%%[![:space:]]*}"}"; verb="${verb%"${verb##*[![:space:]]}"}"
        arg="${arg#"${arg%%[![:space:]]*}"}";    arg="${arg%"${arg##*[![:space:]]}"}"

        if [[ -z "$verb" ]] || [[ -z "$arg" ]]; then
            warn "uninstall.sh: empty verb or arg — '$line'"
            continue
        fi

        case "$verb" in
            apt)        _uninstall_apt        "$arg" ;;
            brew)       _uninstall_brew       "$arg" ;;
            brew-cask)  _uninstall_brew_cask  "$arg" ;;
            font)       _uninstall_brew_cask  "$arg" ;;
            clone)      _uninstall_clone      "$arg" ;;
            zinit)      _uninstall_zinit      "$arg" ;;
            user-bin)   _uninstall_user_bin   "$arg" ;;
            sys-bin)    _uninstall_sys_bin    "$arg" ;;
            *)          warn "uninstall.sh: unknown verb '$verb' (line: '$line')" ;;
        esac
    done < "$manifest"
}

# ─── Verb handlers ───────────────────────────────────────────────────
# Each handler is idempotent: silent when the artifact is absent,
# emits an `info` line only when it actually removes something, and
# downgrades any sub-failure to a `warn` (never aborts the caller).

_uninstall_apt() {
    [[ "$(uname -s)" == Linux* ]] || return 0
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        info "uninstall apt:$pkg (purge + autoremove)"
        sudo apt-get purge -y -qq "$pkg" 2>&1 \
            | sed 's/^/    /' \
            || warn "apt purge $pkg failed"
        sudo apt-get autoremove -y -qq 2>&1 \
            | sed 's/^/    /' \
            || true
    fi
}

_uninstall_brew() {
    [[ "$(uname -s)" == Darwin* ]] || return 0
    local formula="$1"
    local brew_bin="${BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
    [[ -n "$brew_bin" ]] || { warn "uninstall brew:$formula skipped — brew not found"; return 0; }
    if "$brew_bin" list --formula "$formula" >/dev/null 2>&1; then
        info "uninstall brew:$formula (--ignore-dependencies)"
        "$brew_bin" uninstall --ignore-dependencies "$formula" 2>&1 \
            | sed 's/^/    /' \
            || warn "brew uninstall $formula failed"
    fi
}

_uninstall_brew_cask() {
    [[ "$(uname -s)" == Darwin* ]] || return 0
    local cask="$1"
    local brew_bin="${BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
    [[ -n "$brew_bin" ]] || { warn "uninstall brew-cask:$cask skipped — brew not found"; return 0; }
    if "$brew_bin" list --cask "$cask" >/dev/null 2>&1; then
        info "uninstall brew-cask:$cask"
        "$brew_bin" uninstall --cask "$cask" 2>&1 \
            | sed 's/^/    /' \
            || warn "brew uninstall --cask $cask failed"
    fi
}

# Sandbox helper: rejects args that could escape the intended dir.
# Returns 0 if safe, 1 if rejected (with warn already emitted).
_sandbox_name() {
    local verb="$1" arg="$2"
    case "$arg" in
        */*|*..*|/*|"")
            warn "uninstall.sh: $verb:$arg rejected by sandbox (no slashes, no '..')"
            return 1 ;;
    esac
    return 0
}

_uninstall_clone() {
    local name="$1"
    _sandbox_name "clone" "$name" || return 0
    local dir="$HOME/.local/share/$name"
    if [[ -d "$dir" ]]; then
        info "uninstall clone:$name ($dir)"
        rm -rf "$dir"
    fi
}

_uninstall_zinit() {
    local spec="$1"
    # Expect <owner>/<repo>; reject anything else
    case "$spec" in
        */*) ;;
        *)
            warn "uninstall.sh: zinit:$spec malformed (expected owner/repo)"
            return 0 ;;
    esac
    case "$spec" in
        *..*|*//*|/*)
            warn "uninstall.sh: zinit:$spec rejected by sandbox"
            return 0 ;;
    esac
    # zinit cache layout: ~/.local/share/zinit/plugins/<owner>---<repo>
    local mangled="${spec//\//---}"
    local dir="$HOME/.local/share/zinit/plugins/$mangled"
    if [[ -d "$dir" ]]; then
        info "uninstall zinit:$spec ($dir)"
        rm -rf "$dir"
    fi
}

_uninstall_user_bin() {
    local name="$1"
    _sandbox_name "user-bin" "$name" || return 0
    local f="$HOME/.local/bin/$name"
    if [[ -e "$f" ]]; then
        info "uninstall user-bin:$name ($f)"
        rm -f "$f"
    fi
}

_uninstall_sys_bin() {
    local name="$1"
    _sandbox_name "sys-bin" "$name" || return 0
    local f="/usr/local/bin/$name"
    if [[ -e "$f" ]]; then
        info "uninstall sys-bin:$name ($f) — needs sudo"
        sudo rm -f "$f" || warn "sudo rm $f failed"
    fi
}
