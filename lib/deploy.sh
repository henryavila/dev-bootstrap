#!/usr/bin/env bash
# lib/deploy.sh — deploy files from a topic's templates/ directory.
#
# Usage:
#     bash lib/deploy.sh <templates-dir>
#
# Behavior:
#   - If <dir>/DEPLOY exists, reads explicit mappings from it.
#   - Else, uses automatic name-convention mapping.
#   - Files with .template suffix pass through envsubst (requires gettext).
#   - CRLF is stripped from template content.
#   - Existing destination is diffed: no-op if identical, backup-then-overwrite otherwise.
#   - Keeps the 5 most recent backups per destination, pruning older ones.
#   - Destinations outside $HOME trigger sudo (confirmed once at start).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/log.sh"

templates_dir="${1:-}"
if [[ -z "$templates_dir" ]] || [[ ! -d "$templates_dir" ]]; then
    fail "deploy.sh: templates dir missing or not a directory: $templates_dir"
    exit 1
fi

# Ensure envsubst is available for .template files
if ! command -v envsubst >/dev/null 2>&1; then
    fail "envsubst not found (install gettext / gettext-base before running topics with templates)"
    exit 1
fi

sudo_needed=0
declare -a mapping_src mapping_dst

# Variables allowed in template substitution. Restricting the set keeps
# envsubst from mangling unrelated $tokens (e.g. nginx's $project capture,
# shell positional $1, php's $_SERVER). Add here if a new topic needs more.
ENVSUBST_ALLOWLIST='${USER} ${HOME} ${BREW_PREFIX} ${CODE_DIR} ${NGINX_CONF_DIR} ${DOTFILES_DIR}'

# ---------- Build mapping list ----------

expand_dst() {
    # Resolve ~ and allowlisted ${VARS} in the destination path only.
    local raw="$1"
    raw="${raw/#\~/$HOME}"
    printf '%s' "$raw" | envsubst "$ENVSUBST_ALLOWLIST"
}

check_no_empty_refs() {
    # Returns 1 and logs if $raw references any ${VAR} that is currently empty.
    # Used to avoid catastrophic destinations like "/catchall.conf" from an unset var.
    local raw="$1" src_label="$2"
    local rest="$raw" vname missing=0
    while [[ "$rest" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        vname="${BASH_REMATCH[1]}"
        if [[ -z "${!vname:-}" ]]; then
            fail "deploy.sh: DEPLOY references \${$vname} but it is empty (src=$src_label, raw=$raw)"
            missing=1
        fi
        rest="${rest//${BASH_REMATCH[0]}/}"
    done
    return "$missing"
}

auto_map_name() {
    # Given a filename inside templates/ (no dir prefix, .template already stripped),
    # return absolute destination path or empty string if no auto-match.
    local name="$1"
    case "$name" in
        bashrc)                         printf '%s/.bashrc' "$HOME" ;;
        zshrc)                          printf '%s/.zshrc' "$HOME" ;;
        inputrc)                        printf '%s/.inputrc' "$HOME" ;;
        tmux.conf)                      printf '%s/.tmux.conf' "$HOME" ;;
        starship.toml)                  printf '%s/.config/starship.toml' "$HOME" ;;
        bashrc.d-*.sh)
            local rest="${name#bashrc.d-}"
            printf '%s/.bashrc.d/%s' "$HOME" "$rest"
            ;;
        zshrc.d-*.sh)
            local rest="${name#zshrc.d-}"
            printf '%s/.zshrc.d/%s' "$HOME" "$rest"
            ;;
        bin/*)
            local rest="${name#bin/}"
            printf '%s/.local/bin/%s' "$HOME" "$rest"
            ;;
        *)
            printf ''
            ;;
    esac
}

if [[ -f "$templates_dir/DEPLOY" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim trailing whitespace
        line="${line%$'\r'}"
        # Skip blank lines and comments
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        src="${line%%=*}"
        dst="${line#*=}"
        src="${src#"${src%%[![:space:]]*}"}"
        src="${src%"${src##*[![:space:]]}"}"
        dst="${dst#"${dst%%[![:space:]]*}"}"
        dst="${dst%"${dst##*[![:space:]]}"}"

        if [[ -z "$src" ]] || [[ -z "$dst" ]]; then
            warn "deploy.sh: malformed DEPLOY line: $line"
            continue
        fi

        if [[ ! -f "$templates_dir/$src" ]]; then
            warn "deploy.sh: DEPLOY src not found: $src"
            continue
        fi

        if ! check_no_empty_refs "$dst" "$src"; then
            exit 1
        fi

        expanded_dst="$(expand_dst "$dst")"
        mapping_src+=("$src")
        mapping_dst+=("$expanded_dst")
    done < "$templates_dir/DEPLOY"
else
    while IFS= read -r -d '' src_path; do
        rel="${src_path#"$templates_dir"/}"
        # Skip DEPLOY itself even if absent (defensive)
        [[ "$rel" == "DEPLOY" ]] && continue
        # Derive destination name (strip .template suffix if present)
        name="${rel%.template}"
        dst="$(auto_map_name "$name")"
        if [[ -z "$dst" ]]; then
            warn "deploy.sh: no auto-mapping for '$rel' (add DEPLOY file or rename)"
            continue
        fi
        mapping_src+=("$rel")
        mapping_dst+=("$dst")
    done < <(find "$templates_dir" -mindepth 1 -type f -print0)
fi

if [[ "${#mapping_src[@]}" -eq 0 ]]; then
    info "deploy.sh: nothing to deploy from $templates_dir"
    exit 0
fi

# ---------- Detect if sudo will be needed ----------

for dst in "${mapping_dst[@]}"; do
    if [[ "$dst" != "$HOME"/* ]] && [[ "$dst" != "$HOME" ]]; then
        sudo_needed=1
        break
    fi
done

if [[ "$sudo_needed" -eq 1 ]]; then
    info "deploy.sh: destinations outside \$HOME detected — sudo required"
    if ! sudo -v; then
        fail "deploy.sh: sudo not available / denied"
        exit 1
    fi
fi

# ---------- Deploy each file ----------

tmp_staging="$(mktemp -d)"
trap 'rm -rf "$tmp_staging"' EXIT

deploy_one() {
    local src_rel="$1" dst="$2"
    local src_abs="$templates_dir/$src_rel"
    local staged
    staged="$tmp_staging/$(basename "$src_rel")"

    # Read, strip CRLF, and optionally run envsubst (allowlist only)
    if [[ "$src_rel" == *.template ]]; then
        tr -d '\r' < "$src_abs" | envsubst "$ENVSUBST_ALLOWLIST" > "$staged"
    else
        tr -d '\r' < "$src_abs" > "$staged"
    fi

    local dst_dir
    dst_dir="$(dirname "$dst")"

    local needs_sudo=0
    if [[ "$dst" != "$HOME"/* ]] && [[ "$dst" != "$HOME" ]]; then
        needs_sudo=1
    fi

    # Ensure target dir exists
    if [[ ! -d "$dst_dir" ]]; then
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo mkdir -p "$dst_dir"
        else
            mkdir -p "$dst_dir"
        fi
    fi

    # Diff or place
    if [[ -e "$dst" ]]; then
        if cmp -s "$staged" "$dst"; then
            ok "$dst up to date"
            return 0
        fi
        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        local backup="${dst}.bak-${ts}"
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo cp -p "$dst" "$backup"
        else
            cp -p "$dst" "$backup"
        fi
        info "backed up previous $dst → $backup"
        prune_backups "$dst" "$needs_sudo"
    fi

    if [[ "$needs_sudo" -eq 1 ]]; then
        sudo cp "$staged" "$dst"
    else
        cp "$staged" "$dst"
    fi

    # Make scripts under ~/.local/bin/ and bin/ executable
    if [[ "$dst" == "$HOME/.local/bin/"* ]] || [[ "$src_rel" == bin/* ]]; then
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo chmod +x "$dst"
        else
            chmod +x "$dst"
        fi
    fi

    ok "deployed $dst"
}

prune_backups() {
    local dst="$1" needs_sudo="$2"
    local dir base pattern
    dir="$(dirname "$dst")"
    base="$(basename "$dst")"
    pattern="${base}.bak-*"

    # Keep the 5 newest
    local old_files
    # shellcheck disable=SC2012
    old_files="$(ls -1t "$dir"/$pattern 2>/dev/null | tail -n +6 || true)"
    if [[ -z "$old_files" ]]; then
        return 0
    fi
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo rm -f "$f"
        else
            rm -f "$f"
        fi
    done <<< "$old_files"
}

for i in "${!mapping_src[@]}"; do
    deploy_one "${mapping_src[$i]}" "${mapping_dst[$i]}"
done
