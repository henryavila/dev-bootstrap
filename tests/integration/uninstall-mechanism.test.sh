#!/usr/bin/env bash
# tests/integration/uninstall-mechanism.test.sh
#
# Regression: ensure lib/uninstall.sh + per-topic data/uninstall.list
# manifest mechanism stays wired correctly.
#
# Why this exists: removing artifacts is one of the easiest things to
# silently break — a topic's install.<suffix>.sh stops sourcing the lib,
# or the manifest gets renamed, and machines already provisioned never
# get cleaned up. Grep-based static checks catch that drift without
# touching the system.
#
# Companion: tests/integration/git-deprecated-keys-cleanup.test.sh
# guards the git-config-specific drift mechanism (different paradigm,
# same reliability concern).
#
# What this checks:
#   1. lib/uninstall.sh exists and exposes uninstall_apply
#   2. Every supported verb has a handler with the right OS guard
#      (apt → Linux only, brew/brew-cask → Darwin only)
#   3. The 3 sandboxed verbs (clone, user-bin, sys-bin) reject `..` and `/`
#   4. zinit handler converts owner/repo → owner---repo (zinit's cache layout)
#   5. brew handler uses --ignore-dependencies (per project decision Q4)
#   6. apt handler runs autoremove (per project decision Q4)
#   7. Every install.<suffix>.sh that has a sibling data/uninstall.list
#      sources the lib AND calls uninstall_apply on it
#   8. Every data/uninstall.list line uses a known verb

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

LIB="$ROOT/lib/uninstall.sh"

echo
echo "═══ uninstall-mechanism (drift management for installed artifacts) ═══"

# ─── 1. lib exists and exposes the public entry point ───────────────
assert_file_exists "$LIB" "lib/uninstall.sh exists"
assert_pattern_present "$LIB" '^uninstall_apply\(\)' \
    "lib/uninstall.sh defines uninstall_apply()"

# ─── 2. Each verb has a handler ─────────────────────────────────────
for verb_handler in \
    "_uninstall_apt"        \
    "_uninstall_brew"       \
    "_uninstall_brew_cask"  \
    "_uninstall_clone"      \
    "_uninstall_zinit"      \
    "_uninstall_user_bin"   \
    "_uninstall_sys_bin"    ; do
    assert_pattern_present "$LIB" "^${verb_handler}\\(\\)" \
        "handler $verb_handler defined"
done

# ─── OS guards ──────────────────────────────────────────────────────
# apt block must guard on Linux (else early-return on Mac)
apt_block="$(awk '/^_uninstall_apt\(\)/,/^}/' "$LIB")"
assert_contains "$apt_block" 'uname -s' \
    "_uninstall_apt checks uname (OS guard)"
assert_contains "$apt_block" 'Linux' \
    "_uninstall_apt guards on Linux"

brew_block="$(awk '/^_uninstall_brew\(\)/,/^}/' "$LIB")"
assert_contains "$brew_block" 'Darwin' \
    "_uninstall_brew guards on Darwin"

cask_block="$(awk '/^_uninstall_brew_cask\(\)/,/^}/' "$LIB")"
assert_contains "$cask_block" 'Darwin' \
    "_uninstall_brew_cask guards on Darwin"

# ─── 3. Sandbox protection on rm-based verbs ────────────────────────
assert_pattern_present "$LIB" '_sandbox_name' \
    "_sandbox_name helper exists (shared sandbox)"

# clone, user-bin, sys-bin all use sandbox
for fn in _uninstall_clone _uninstall_user_bin _uninstall_sys_bin; do
    block="$(awk "/^${fn}\\(\\)/,/^}/" "$LIB")"
    if echo "$block" | grep -qE '_sandbox_name|\\.\\.|/\\*' ; then
        pass "$fn rejects path-traversal args"
    else
        fail "$fn missing path-traversal sandbox"
    fi
done

# ─── 4. zinit handler maps owner/repo → owner---repo ────────────────
zinit_block="$(awk '/^_uninstall_zinit\(\)/,/^}/' "$LIB")"
assert_contains "$zinit_block" '---' \
    "_uninstall_zinit produces zinit cache mangled name (--- separator)"
assert_contains "$zinit_block" '.local/share/zinit/plugins' \
    "_uninstall_zinit targets the zinit plugin cache dir"

# ─── 5. brew uses --ignore-dependencies (project decision Q4) ───────
assert_contains "$brew_block" '--ignore-dependencies' \
    "_uninstall_brew uses --ignore-dependencies (Q4: always force-remove)"

# ─── 6. apt runs autoremove (project decision Q4) ───────────────────
assert_contains "$apt_block" 'autoremove' \
    "_uninstall_apt runs autoremove (Q4: clean orphan deps)"

# ─── 7. Topic install.<suffix>.sh ↔ data/uninstall.list wiring ──────
# For every data/uninstall.list found under topics/, the corresponding
# install scripts must source the lib AND call uninstall_apply.
echo
echo "═══ per-topic wiring ═══"

mapfile -t manifests < <(find "$ROOT/topics" -mindepth 3 -maxdepth 4 \
    -path '*/data/uninstall.list' -type f 2>/dev/null | sort)

if [[ "${#manifests[@]}" -eq 0 ]]; then
    pass "no data/uninstall.list manifests yet (mechanism unused — OK)"
else
    for manifest in "${manifests[@]}"; do
        topic_dir="$(dirname "$(dirname "$manifest")")"
        topic_name="$(basename "$topic_dir")"

        # Each manifest must have at least one consumer install script.
        # Scripts may be install.sh, install.mac.sh, or install.wsl.sh.
        consumers=("$topic_dir"/install.sh "$topic_dir"/install.mac.sh "$topic_dir"/install.wsl.sh)
        any_wired=0
        for script in "${consumers[@]}"; do
            [[ -f "$script" ]] || continue
            if grep -q 'lib/uninstall.sh' "$script" \
               && grep -q 'uninstall_apply' "$script"; then
                pass "$topic_name/$(basename "$script") sources lib + calls uninstall_apply"
                any_wired=1
            fi
        done
        if [[ "$any_wired" -eq 0 ]]; then
            fail "$topic_name has data/uninstall.list but no install script wires it"
        fi

        # ─── 8. Every line uses a known verb ────────────────────────
        known_verbs='^(apt|brew|brew-cask|font|clone|zinit|user-bin|sys-bin):'
        bad="$(grep -vE "$known_verbs" "$manifest" | grep -vE '^[[:space:]]*(#|$)' || true)"
        if [[ -z "$bad" ]]; then
            pass "$topic_name/data/uninstall.list — all lines use known verbs"
        else
            fail "$topic_name/data/uninstall.list — unknown verbs found:"
            echo "$bad" | sed 's/^/        /' >&2
        fi
    done
fi

summary
