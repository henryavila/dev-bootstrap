#!/usr/bin/env bash
# personal-clone.sh — clone personal repos from identity's personal-repos.list.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/env.sh
. "$HERE/env.sh"
# shellcheck source=lib/log.sh
. "$HERE/log.sh"

REPO_LIST="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/shell/personal-repos.list"

_usage() {
    cat <<'EOF'
Usage: mesh personal-clone [--dry-run] [--list]

Clone personal repos listed in $MESH_IDENTITY_DIR/shell/personal-repos.list.
Each repo is cloned under $HOME/<name>. Existing repos are skipped (idempotent).

Options:
  --dry-run   Show what would be cloned without cloning
  --list      Print the repo catalog and exit
  -h, --help  Show this help
EOF
}

_die() { log_error "$*"; exit 2; }

DRY_RUN=false
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)  DRY_RUN=true; shift ;;
        --list)     LIST_ONLY=true; shift ;;
        -h|--help)  _usage; exit 0 ;;
        *)          _die "unknown option: $1" ;;
    esac
done

[[ -r "$REPO_LIST" ]] || _die "repo list not found: $REPO_LIST"

declare -a cloned=() skipped=() failed=()

_clone_one() {
    local name="$1" url="$2" branch="$3"
    local dest="$HOME/$name"

    if [[ -d "$dest/.git" ]]; then
        local cur_branch
        cur_branch=$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")
        log_info "skip $name (already cloned, on $cur_branch)"
        skipped+=("$name")
        return 0
    fi

    if [[ -e "$dest" ]]; then
        log_warn "$dest exists but is not a git repo — skipping"
        failed+=("$name")
        return 1
    fi

    if "$DRY_RUN"; then
        log_info "[dry-run] would clone $name ($branch) from $url"
        cloned+=("$name")
        return 0
    fi

    mkdir -p "$(dirname "$dest")"
    log_info "cloning $name ($branch)"
    if git clone --branch "$branch" "$url" "$dest" 2>&1 | tail -5; then
        cloned+=("$name")
    else
        log_error "clone failed for $name"
        failed+=("$name")
    fi
}

_read_catalog() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        echo "$line"
    done < "$REPO_LIST"
}

if "$LIST_ONLY"; then
    _read_catalog
    exit 0
fi

while IFS='|' read -r name url branch; do
    _clone_one "$name" "$url" "$branch" || true
done < <(_read_catalog)

echo
log_info "--- Summary ---"
log_info "cloned:  ${#cloned[@]}  ${cloned[*]:-}"
log_info "skipped: ${#skipped[@]}  ${skipped[*]:-}"
[[ ${#failed[@]} -gt 0 ]] && log_warn "failed:  ${#failed[@]}  ${failed[*]:-}"
echo
