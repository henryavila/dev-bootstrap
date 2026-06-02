#!/usr/bin/env bash
# shellcheck shell=bash
# lib/secrets.sh — mesh-workstation shared secrets file (sourced, not executed).
#
# Purpose:
#   Runtime loader + format for the secrets.env env-token store the install
#   engine sources before running topics (so installers see ngrok authtoken,
#   LLM API keys, Tailscale auth-key, etc).
#
#   NOTE (secrets layer, 2026-06): the canonical, REPLICATED source of these
#   tokens is now the git-crypt-encrypted secrets/secrets.env in the identity
#   repo, managed via `mesh secret add` and deployed here by `mesh secret
#   deploy`. This file is now ONLY the runtime loader + on-disk format.
#   `secrets_set` is RETIRED for new captures (audit T-003): to add a token use
#   `mesh secret add` (encrypted + replicated), never a local-only write. The
#   function is kept so existing callers + the format round-trip, not as the
#   recommended path. See docs/2026-06-02-secrets-layer-spec.md.
#
# Public API (all functions are safe to call multiple times):
#   secrets_init               create $MESH_SECRETS_FILE with
#                              header comment if missing; parent dir
#                              0700, file 0600.
#   secrets_load               source the file if present + safe.
#                              Refuses a world/group-readable file
#                              after attempting a chmod 0600 fix-up.
#   secrets_set <KEY> <VALUE>  upsert KEY=VALUE atomically. Refuses
#                              values containing newlines. printf %q
#                              quotes so spaces / specials round-trip.
#   secrets_has <KEY>          exit 0 iff KEY is already non-empty in
#                              the environment OR present in the file.
#
# File format:
#   shell-sourceable `export KEY=value` lines (printf %q-quoted).
#   Header comment documents intent. Edit by hand is OK, but prefer
#   secrets_set for atomicity.
#
# Path:
#   $MESH_SECRETS_FILE (default $XDG_STATE_HOME/mesh/secrets.env, i.e.
#   ~/.local/state/mesh/secrets.env). This is the SAME path `mesh secret deploy`
#   writes, so there is one canonical secrets.env per host. The pre-rename
#   location (~/.local/state/mesh-workstation/secrets.env) is migrated as part
#   of the whole-state-dir move in lib/state-dir.sh (audit T-004).
#
# What belongs here:
#   NGROK_AUTHTOKEN, OPENAI_API_KEY, ANTHROPIC_API_KEY, GEMINI_API_KEY,
#   HF_TOKEN, TAILSCALE_AUTHKEY, CLOUDFLARE_API_TOKEN, and similar
#   input-only secrets whose upstream CLI does not manage its own store.
#
# What does NOT belong here:
#   - GITHUB_TOKEN / GH_TOKEN — `gh auth login` handles this.
#   - AWS_* — `~/.aws/credentials` is the canonical store.
#   - ATUIN_KEY — `atuin login` writes ~/.local/share/atuin/session.
#   - SSH keys, GPG keys — agents + proper keychains.
#   - DB passwords — `~/.my.cnf`, `~/.pgpass`, driver-specific files.
#
# Rationale for rejecting the above: every one of those tools has a
# native credential store that gives richer guarantees (rotation,
# keyring integration, encryption at rest, per-host isolation). This
# file is a last resort for tools that DON'T, so we don't undermine
# the ones that DO.

# Canonical state dir (audit T-003): unified ~/.local/state/mesh, shared with
# `mesh secret deploy`. The legacy ~/.local/state/mesh-workstation path is
# migrated by lib/state-dir.sh (mesh_migrate_legacy_state), run by setup.sh +
# install-engine before secrets are read. MESH_STATE_DIR is the same override
# var lib/state-dir.sh's mesh_state_dir() reads, so both agree (audit T-004/T-011
# renamed the old BOOTSTRAP_STATE_DIR / BOOTSTRAP_SECRETS_FILE to MESH_*).
: "${MESH_STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/mesh}"
: "${MESH_SECRETS_FILE:=$MESH_STATE_DIR/secrets.env}"
export MESH_STATE_DIR MESH_SECRETS_FILE

# The pre-rename secrets.env is migrated as part of the whole-state-dir move in
# lib/state-dir.sh (mesh_migrate_legacy_state), which setup.sh + install-engine
# run before any secret is read (audit T-004). No secrets-specific migration
# lives here — the state dir is migrated as a unit.

# Fallback logging — when sourced standalone (tests), lib/log.sh may
# not be in scope. Define minimal no-color info/warn so every public
# function can emit diagnostics without crashing under set -u.
if ! declare -F warn >/dev/null 2>&1; then
    warn() { printf '! %s\n' "$*" >&2; }
fi
if ! declare -F info >/dev/null 2>&1; then
    info() { printf '→ %s\n' "$*"; }
fi
if ! declare -F ok >/dev/null 2>&1; then
    ok() { printf '✓ %s\n' "$*"; }
fi

# _secrets_mode — cross-platform (`stat` differs GNU vs BSD) octal mode
# of a file. Last resort: perl, which exists on every mesh-workstation
# target OS (WSL Ubuntu ships perl in base; macOS ships it too).
_secrets_mode() {
    local f="$1"
    local m
    if m="$(stat -c '%a' "$f" 2>/dev/null)"; then printf '%s' "$m"; return; fi
    if m="$(stat -f '%A' "$f" 2>/dev/null)"; then printf '%s' "$m"; return; fi
    perl -e 'printf "%o", (stat($ARGV[0]))[2] & 07777' "$f" 2>/dev/null
}

secrets_init() {
    local dir="$MESH_STATE_DIR"
    local file="$MESH_SECRETS_FILE"
    local prev_umask
    prev_umask="$(umask)"
    # umask 077 → any file/dir created inside this block is owner-only.
    umask 077
    mkdir -p "$dir"
    chmod 0700 "$dir" 2>/dev/null || true
    if [[ ! -f "$file" ]]; then
        cat > "$file" <<'EOF'
# mesh-workstation — local secrets file (mode 0600).
# Sourced by setup.sh BEFORE any topic runs, so installers
# see these vars in their env.
#
# Format: one `export KEY=value` per line (printf %q-quoted).
# Edit by hand or use `secrets_set KEY VALUE` from lib/secrets.sh.
# Delete this file to reset (your tokens, not your configs).
#
# DO NOT commit. DO NOT `cat` in shared sessions (atuin syncs
# your history). DO rotate tokens at the upstream dashboard if
# this file is ever exposed.
#
# Suitable: NGROK_AUTHTOKEN, OPENAI_API_KEY, ANTHROPIC_API_KEY,
#           GEMINI_API_KEY, HF_TOKEN, TAILSCALE_AUTHKEY,
#           CLOUDFLARE_API_TOKEN.
# Not suitable (use native store): GITHUB_TOKEN (gh auth),
#           AWS_* (~/.aws), ATUIN_KEY (atuin login),
#           SSH/GPG keys, DB passwords.
EOF
        chmod 0600 "$file" 2>/dev/null || true
    fi
    umask "$prev_umask"
}

secrets_load() {
    local file="$MESH_SECRETS_FILE"
    [[ ! -f "$file" ]] && return 0

    local mode
    mode="$(_secrets_mode "$file")"
    # Accept 600 (rw owner) or 400 (r owner). Anything else is loose.
    if [[ "$mode" != "600" && "$mode" != "400" ]]; then
        warn "secrets file mode $mode is too loose — tightening to 0600 ($file)"
        if ! chmod 0600 "$file" 2>/dev/null; then
            warn "could not chmod 0600 $file — refusing to source (other users may read)"
            return 1
        fi
    fi
    # shellcheck disable=SC1090
    source "$file"
}

secrets_set() {
    local key="$1" value="$2" file="$MESH_SECRETS_FILE"
    if [[ -z "$key" ]]; then
        warn "secrets_set: empty key — ignoring"
        return 1
    fi
    if [[ "$value" == *$'\n'* ]]; then
        warn "secrets_set: value for $key contains newlines — refusing"
        return 1
    fi

    secrets_init

    local prev_umask
    prev_umask="$(umask)"
    umask 077

    local tmp="${file}.tmp.$$"
    # Preserve every non-matching line (including comments + other keys).
    if [[ -f "$file" ]]; then
        grep -v -E "^export ${key}=" "$file" > "$tmp" 2>/dev/null || : > "$tmp"
    else
        : > "$tmp"
    fi
    printf 'export %s=%q\n' "$key" "$value" >> "$tmp"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$file"

    umask "$prev_umask"
}

secrets_has() {
    local key="$1"
    [[ -z "$key" ]] && return 1
    # Already-exported env wins — user's invocation `NGROK_AUTHTOKEN=x
    # bash setup.sh` counts as "have it".
    if [[ -n "${!key:-}" ]]; then
        return 0
    fi
    [[ ! -f "$MESH_SECRETS_FILE" ]] && return 1
    grep -qE "^export ${key}=" "$MESH_SECRETS_FILE" 2>/dev/null
}
