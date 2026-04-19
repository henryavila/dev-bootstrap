#!/usr/bin/env bash
# bootstrap.sh — run every topic in order on this machine.
#
# Env vars:
#   SKIP_TOPICS         space-separated list of topics to skip
#   ONLY_TOPICS         space-separated list of topics to run exclusively
#   DRY_RUN=1           print actions without executing
#   DOTFILES_REPO       personal dotfiles repo URL (enables 95-dotfiles-personal)
#   DOTFILES_DIR        where to clone dotfiles (default: ~/dotfiles)
#   GIT_NAME, GIT_EMAIL identity for 50-git
#   CODE_DIR            project root (default: ~/code/web)
#   INCLUDE_LARAVEL=1   enables 60-laravel-stack
#   INCLUDE_REMOTE=1    enables 70-remote-access
#   INCLUDE_EDITOR=1    enables 90-editor
#   NO_COLOR=1          disable colored output (auto if not a TTY)
#
# Usage: bash bootstrap.sh [--help]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# shellcheck disable=SC1091
source "$HERE/lib/log.sh"

usage() {
    cat <<'EOF'
dev-bootstrap — set up a development machine

Usage:
  bash bootstrap.sh                 run every topic in order
  DRY_RUN=1 bash bootstrap.sh       print actions without executing
  SKIP_TOPICS="NN-x" ...            skip specific topics
  ONLY_TOPICS="NN-x NN-y" ...       run only these topics
  bash bootstrap.sh --help          this message

Opt-in topics (require env var):
  60-laravel-stack      INCLUDE_LARAVEL=1
  70-remote-access      INCLUDE_REMOTE=1
  90-editor             INCLUDE_EDITOR=1
  95-dotfiles-personal  DOTFILES_REPO=<url>

Useful env vars:
  GIT_NAME, GIT_EMAIL, CODE_DIR, DOTFILES_DIR, NO_COLOR

See topics/*/README.md for topic-specific documentation.
EOF
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

# ---------- Detect OS ----------
OS="$(bash "$HERE/lib/detect-os.sh")"
export OS

if [[ "$OS" == "unknown" ]]; then
    fail "unsupported OS (uname -s = $(uname -s))"
    exit 1
fi

banner "dev-bootstrap :: $OS"

# ---------- Detect Brew (macOS only, best-effort) ----------
BREW_BIN=""
BREW_PREFIX=""
if [[ "$OS" == "mac" ]]; then
    if out=$(bash "$HERE/lib/detect-brew.sh" 2>/dev/null); then
        eval "$out"
        info "brew found at $BREW_BIN (prefix $BREW_PREFIX)"
    else
        warn "brew not installed yet; topic 00-core will install it"
    fi
fi
export BREW_BIN BREW_PREFIX

# ---------- Defaults for inherited vars ----------
export DOTFILES_REPO="${DOTFILES_REPO:-}"
export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
export GIT_NAME="${GIT_NAME:-}"
export GIT_EMAIL="${GIT_EMAIL:-}"
export CODE_DIR="${CODE_DIR:-$HOME/code/web}"
export INCLUDE_LARAVEL="${INCLUDE_LARAVEL:-0}"
export INCLUDE_REMOTE="${INCLUDE_REMOTE:-0}"
export INCLUDE_EDITOR="${INCLUDE_EDITOR:-0}"
export NO_COLOR="${NO_COLOR:-}"

# ---------- Collect topics ----------
mapfile -t all_topics < <(find "$HERE/topics" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

in_list() {
    local needle="$1"
    shift
    for x in "$@"; do
        [[ "$x" == "$needle" ]] && return 0
    done
    return 1
}

# Opt-in gating map: topic_name → env var that must equal 1
optin_var_for() {
    case "$1" in
        60-laravel-stack) echo "INCLUDE_LARAVEL" ;;
        70-remote-access) echo "INCLUDE_REMOTE" ;;
        90-editor)        echo "INCLUDE_EDITOR" ;;
        *)                echo "" ;;
    esac
}

# ---------- Log file ----------
LOG="/tmp/dev-bootstrap-$OS-$(date +%Y%m%d-%H%M%S).log"
info "full log: $LOG"

# shellcheck disable=SC2206
skip_list=(${SKIP_TOPICS:-})
# shellcheck disable=SC2206
only_list=(${ONLY_TOPICS:-})

declare -a passed=() failed=() skipped=()

run_topic() {
    local topic="$1"
    local dir="$HERE/topics/$topic"

    # Opt-in gate
    local var
    var="$(optin_var_for "$topic")"
    if [[ -n "$var" ]]; then
        local val="${!var:-0}"
        if [[ "$val" != "1" ]]; then
            info "skip $topic (opt-in: set $var=1 to enable)"
            skipped+=("$topic")
            return 0
        fi
    fi

    # 95-dotfiles-personal gate: requires DOTFILES_REPO
    if [[ "$topic" == "95-dotfiles-personal" ]] && [[ -z "$DOTFILES_REPO" ]]; then
        info "skip $topic (set DOTFILES_REPO to enable)"
        skipped+=("$topic")
        return 0
    fi

    # Resolve installer
    local installer=""
    if [[ -f "$dir/install.$OS.sh" ]]; then
        installer="$dir/install.$OS.sh"
    elif [[ -f "$dir/install.sh" ]]; then
        installer="$dir/install.sh"
    fi

    if [[ -z "$installer" ]] && [[ ! -d "$dir/templates" ]]; then
        info "skip $topic (no installer, no templates)"
        skipped+=("$topic")
        return 0
    fi

    banner "topic :: $topic"

    if [[ -n "$installer" ]]; then
        if [[ "${DRY_RUN:-}" == "1" ]]; then
            info "would run: $installer"
        else
            if ! bash "$installer" 2>&1 | tee -a "$LOG"; then
                fail "$topic installer failed"
                failed+=("$topic")
                return 0
            fi
        fi
    fi

    if [[ -d "$dir/templates" ]]; then
        if [[ "${DRY_RUN:-}" == "1" ]]; then
            info "would deploy: $dir/templates"
        else
            if ! bash "$HERE/lib/deploy.sh" "$dir/templates" 2>&1 | tee -a "$LOG"; then
                fail "$topic templates deploy failed"
                failed+=("$topic")
                return 0
            fi
        fi
    fi

    passed+=("$topic")
}

for topic in "${all_topics[@]}"; do
    if [[ "${#only_list[@]}" -gt 0 ]] && ! in_list "$topic" "${only_list[@]}"; then
        continue
    fi
    if in_list "$topic" "${skip_list[@]}"; then
        info "skip $topic (SKIP_TOPICS)"
        skipped+=("$topic")
        continue
    fi
    run_topic "$topic"
done

# ---------- Summary ----------
banner "summary"
printf '  passed : %d  (%s)\n' "${#passed[@]}"  "${passed[*]:-}"
printf '  failed : %d  (%s)\n' "${#failed[@]}"  "${failed[*]:-}"
printf '  skipped: %d  (%s)\n' "${#skipped[@]}" "${skipped[*]:-}"

if [[ "${#failed[@]}" -gt 0 ]]; then
    fail "some topics failed — see $LOG"
    exit 1
fi

ok "done"
