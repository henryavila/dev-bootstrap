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
# OAuth device flow via browser — 1 token per machine, revokable
# independently.
#
# CRITICAL: `gh auth login` MUST run against a real TTY. Our parent
# (bootstrap.sh:276) invokes topics via `bash installer 2>&1 | tee
# -a LOG` — the `| tee` makes stdout/stderr non-TTY. When gh detects
# non-TTY, it SKIPS the "Press Enter to continue" pause built into
# its interactive flow and starts polling GitHub's OAuth endpoint
# IMMEDIATELY, before the user can copy the one-time code + approve
# it in the browser. GitHub then rate-limits (`slow_down` response
# per RFC 8628), which gh 2.x treats as a fatal error. The auth
# "fails" in seconds — but the real cause is the missing TTY, not
# the user being slow.
#
# Fix: bind stdin/stdout/stderr of `gh auth login` to /dev/tty —
# the controlling terminal that exists for any shell session
# launched from a user TTY. This bypasses the tee pipe for just
# this command; gh sees a real terminal and behaves normally
# (pauses for Press Enter, starts polling only after user is
# actually ready).
#
# NON_INTERACTIVE=1 + GITHUB_TOKEN path skips TTY entirely (CI).
if gh auth status >/dev/null 2>&1; then
    ok "gh already authenticated ($(gh api user -q .login 2>/dev/null || echo 'unknown'))"
else
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
        info "authenticating gh via GITHUB_TOKEN (non-interactive)"
        echo "$GITHUB_TOKEN" | gh auth login --with-token
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        info "authenticating gh interactively (/dev/tty — bypasses tee pipe)"
        info ""
        info "gh will pause and ask you to press Enter before opening the browser."
        info "Scopes: admin:public_key (register SSH key) + repo (clone private)."
        info ""
        # --git-protocol https (NOT ssh): with --git-protocol ssh, gh's
        # interactive flow offers to generate a new SSH key automatically
        # and register it as "GitHub CLI" — creating a SECOND key
        # alongside the one this script generates below. Using https for
        # git-protocol means gh uses HTTPS credential helper for clones
        # (handled by `gh auth setup-git`) while we stay in full control
        # of the SSH key (generation, title, registration via `gh ssh-key
        # add` with our own fingerprint-idempotent logic).
        #
        # --clipboard: gh auto-copies the OAuth device code to the OS
        # clipboard (via pbcopy on Mac, xclip on Linux/WSLg, or xsel).
        # If the clipboard tool is missing OR fails, gh gracefully
        # falls back to just printing the code — no regression vs
        # the plain flow. On installed systems it saves a mouse select
        # + copy per machine provisioning.
        if ! gh auth login --web --clipboard \
                --git-protocol https \
                --scopes "admin:public_key,repo" \
                --hostname github.com \
                </dev/tty >/dev/tty 2>&1; then
            fail "gh auth login failed"
            info ""
            info "This is unexpected now that we're using /dev/tty. Possible causes:"
            info "  - Actual GitHub rate-limit (5-10 failed attempts in ~5 min)"
            info "    → wait 5min, re-run bootstrap (idempotent — skips completed topics)"
            info "  - Network blocking github.com"
            info "    → test: curl -v https://api.github.com/"
            info "  - gh version issue"
            info "    → test: gh --version ; gh auth status"
            exit 1
        fi
    else
        fail "no /dev/tty available and GITHUB_TOKEN not set"
        info "Headless setup: set GITHUB_TOKEN env var with a PAT that has"
        info "admin:public_key,repo scopes, then re-run with NON_INTERACTIVE=1."
        exit 1
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
