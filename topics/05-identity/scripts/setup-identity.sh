#!/usr/bin/env bash
# 05-identity/scripts/setup-identity.sh
# Cross-platform identity bootstrap: gh auth + SSH key + GitHub registration.
#
# Called by install.wsl.sh and install.mac.sh after gh CLI is installed.
# Idempotent — safe to re-run; checks each step before acting.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../lib/log.sh"

# ─── 1. Authenticate gh ─────────────────────────────────────────────
# Uses OAuth device flow via browser — 1 token per machine, revokable
# independently. If NON_INTERACTIVE=1 and GITHUB_TOKEN env var is set,
# use token login instead (for CI / headless).
if gh auth status >/dev/null 2>&1; then
    ok "gh already authenticated ($(gh api user -q .login 2>/dev/null || echo 'unknown'))"
else
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
        info "authenticating gh via GITHUB_TOKEN (non-interactive)"
        echo "$GITHUB_TOKEN" | gh auth login --with-token
    else
        info "gh needs authentication — device flow (browser):"
        info "  1. You'll see an 8-char code (e.g. ABCD-1234)"
        info "  2. Browser opens to github.com/login/device"
        info "  3. Paste the code and click 'Authorize github'"
        info ""
        # --web: opens browser automatically
        # --git-protocol ssh: git remote URLs will use SSH (matches our ssh key)
        # --scopes: admin:public_key (register SSH key) + repo (clone private)
        if ! gh auth login --web --git-protocol ssh \
                --scopes "admin:public_key,repo" --hostname github.com; then
            fail "gh auth login failed — cannot continue"
            exit 1
        fi
    fi
fi

# ─── 2. Git credential helper ──────────────────────────────────────
# Makes HTTPS git clones use the gh-stored token transparently.
# Idempotent — no-op if already configured.
info "configuring git credential helper"
gh auth setup-git 2>/dev/null || true

# ─── 3. Generate SSH key if missing ────────────────────────────────
# ed25519 is the current standard — shorter keys, same security as RSA-3072.
# No passphrase: machine-local identity; disk encryption + OS login handle
# at-rest protection.
if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    ok "SSH key already exists at ~/.ssh/id_ed25519"
else
    info "generating SSH key (no passphrase)"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" \
        -C "${USER}@$(hostname -s)" \
        -f "$HOME/.ssh/id_ed25519" \
        -q
    chmod 600 "$HOME/.ssh/id_ed25519"
    chmod 644 "$HOME/.ssh/id_ed25519.pub"
    ok "SSH key created — comment: ${USER}@$(hostname -s)"
fi

# ─── 4. Register SSH pubkey on GitHub ──────────────────────────────
# Idempotent: compare by fingerprint (stable across uploads).
fingerprint="$(ssh-keygen -lf "$HOME/.ssh/id_ed25519.pub" | awk '{print $2}')"
title="$(hostname -s)"

if gh ssh-key list 2>/dev/null | grep -q "$fingerprint"; then
    ok "SSH key already registered on GitHub (title: matching fingerprint)"
else
    info "registering SSH key on GitHub as \"$title\""
    if gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$title"; then
        ok "SSH key registered"
    else
        warn "gh ssh-key add failed — the token may lack admin:public_key scope"
        warn "register manually: https://github.com/settings/ssh/new"
        warn "then run 'gh auth refresh -s admin:public_key' and re-run this topic"
    fi
fi

# ─── 5. Smoke test: SSH to GitHub ──────────────────────────────────
# BatchMode=yes fails fast if credentials are missing instead of prompting.
# StrictHostKeyChecking=accept-new auto-accepts GitHub's host key on first
# contact (safer than 'no' which also accepts changed keys = MITM risk).
info "verifying SSH authentication to github.com"
ssh_output=$(ssh -T -o BatchMode=yes \
                  -o StrictHostKeyChecking=accept-new \
                  git@github.com 2>&1 || true)
if echo "$ssh_output" | grep -q "successfully authenticated"; then
    ok "SSH auth to GitHub: working"
else
    warn "SSH auth not yet working — GitHub may need a few seconds to index the key"
    warn "Retry manually: ssh -T git@github.com"
fi

ok "identity setup complete"
