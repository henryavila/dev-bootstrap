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
# independently. If NON_INTERACTIVE=1 and GITHUB_TOKEN env var is set,
# uses token login (no browser, for CI/headless).
#
# Retry logic: gh CLI 2.x has a bug where the OAuth `slow_down` response
# (RFC 8628 rate-limit signal) is treated as fatal instead of
# exponential backoff. First attempt often fails if the user takes
# >15s to open the browser + paste code. Retry with 90s pause resets
# GitHub's per-device rate window.
if gh auth status >/dev/null 2>&1; then
    ok "gh already authenticated ($(gh api user -q .login 2>/dev/null || echo 'unknown'))"
else
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
        info "authenticating gh via GITHUB_TOKEN (non-interactive)"
        echo "$GITHUB_TOKEN" | gh auth login --with-token
    else
        cat <<'BANNER'

  ╭──────────────────────────────────────────────────────────────╮
  │  GitHub authentication — OAuth device flow                   │
  ╰──────────────────────────────────────────────────────────────╯

    ➜ gh will print an 8-character code (e.g. ABCD-1234)
    ➜ Open this URL in any browser (phone works, doesn't need to
      be on this machine):

         https://github.com/login/device

    ➜ Paste the code, approve "github" scopes.
    ➜ Come back here — bootstrap resumes automatically.

    Tips:
      - Have the browser tab already open BEFORE the code appears
        so you can paste it immediately (gh poll-then-fail bug:
        slow humans trigger rate-limit).
      - If the first attempt fails, we retry automatically.

BANNER
        sleep 2   # let user read the banner before gh floods output

        auth_ok=0
        for attempt in 1 2 3; do
            info "auth attempt $attempt/3"
            if gh auth login --web \
                    --git-protocol ssh \
                    --scopes "admin:public_key,repo" \
                    --hostname github.com; then
                auth_ok=1
                break
            fi
            if [ "$attempt" -lt 3 ]; then
                warn "gh auth login failed (likely GitHub rate-limit on OAuth poll)"
                warn "waiting 90s for the rate window to reset before retry..."
                sleep 90
            fi
        done

        if [ "$auth_ok" -eq 0 ]; then
            fail "gh auth login failed after 3 attempts"
            cat <<'RECOVERY'

  Manual recovery:
    1. Wait ~5 minutes (GitHub rate-limit reset window).
    2. Run:
         gh auth login --hostname github.com --git-protocol ssh \
             --scopes 'admin:public_key,repo' --web
    3. Re-run bootstrap — topic 05-identity is idempotent and will
       skip the auth step once gh is authenticated.

RECOVERY
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
