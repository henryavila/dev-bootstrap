#!/usr/bin/env bash
# bootstrap.sh — run every topic in order on this machine.
#
# Interactive by default: prompts for opt-in topics and identity via whiptail.
# Skip the menu by passing --non-interactive or pre-seeding any control var.
#
# Env vars (primarily for automation/CI):
#   NON_INTERACTIVE=1   skip the menu even on a TTY
#   SKIP_TOPICS         space-separated list of topics to skip
#   ONLY_TOPICS         space-separated list of topics to run exclusively
#   DRY_RUN=1           print actions without executing
#   DOTFILES_REPO       personal dotfiles repo URL (enables 95-dotfiles-personal)
#   DOTFILES_DIR        where to clone dotfiles (default: ~/dotfiles)
#   GIT_NAME, GIT_EMAIL identity for 50-git
#   GPG_SIGN=1          enable commit/tag signing in 50-git (opt-in)
#   GPG_KEY_ID          explicit signing key (else first secret key is picked)
#   CODE_DIR            project root (default: ~/code/web)
#   INCLUDE_DOCKER=1    enables 45-docker
#   INCLUDE_LARAVEL=1   enables 60-laravel-stack
#   INCLUDE_REMOTE=1    enables 70-remote-access
#   INCLUDE_EDITOR=1    enables 90-editor
#   NO_COLOR=1          disable colored output (auto if not a TTY)
#
# Usage: bash bootstrap.sh [--help] [--non-interactive]

set -euo pipefail

# Minimal shells (docker run, `su -`, some cron contexts, `env -i`) leave $USER
# unset even when the effective UID is a real account. `id -un` always works.
# Exported so every topic + envsubst in lib/deploy.sh sees a consistent value.
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# shellcheck disable=SC1091
source "$HERE/lib/log.sh"

usage() {
    cat <<'EOF'
dev-bootstrap — set up a development machine

Interactive mode (default):
  bash bootstrap.sh                 prompts for opt-ins + identity, then runs

Automation / CI mode:
  NON_INTERACTIVE=1 bash bootstrap.sh       skip menu even on a TTY
  bash bootstrap.sh --non-interactive       same, flag form
  DRY_RUN=1 bash bootstrap.sh               print actions without executing
  bash bootstrap.sh --dry-run               same, flag form
  SKIP_TOPICS="NN-x" ...                    skip specific topics
  ONLY_TOPICS="NN-x NN-y" ...               run only these topics

Opt-in topics (menu toggles these, or set env var in automation):
  45-docker             INCLUDE_DOCKER=1
  60-laravel-stack      INCLUDE_LARAVEL=1
  70-remote-access      INCLUDE_REMOTE=1
  90-editor             INCLUDE_EDITOR=1
  95-dotfiles-personal  DOTFILES_REPO=<url>

Other env vars:
  GIT_NAME, GIT_EMAIL, CODE_DIR, DOTFILES_DIR, NO_COLOR
  GPG_SIGN=1 [+ GPG_KEY_ID=<id>]  enable GPG commit signing in 50-git

See topics/*/README.md for topic-specific documentation.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --non-interactive)
            export NON_INTERACTIVE=1
            ;;
        --dry-run)
            export DRY_RUN=1
            ;;
    esac
done

# ---------- Detect OS ----------
OS="$(bash "$HERE/lib/detect-os.sh")"
export OS

if [[ "$OS" == "unknown" ]]; then
    fail "unsupported OS (uname -s = $(uname -s))"
    exit 1
fi

banner "dev-bootstrap :: $OS"

# ---------- Detect Brew (macOS only; may be absent on fresh install) ----------
BREW_BIN=""
BREW_PREFIX=""

detect_brew_if_mac() {
    # Populates BREW_BIN and BREW_PREFIX. Safe to call repeatedly — on WSL/Linux
    # it's a no-op. On Mac it refreshes both if brew has since been installed.
    if [[ "$OS" != "mac" ]]; then
        return 0
    fi
    if out=$(bash "$HERE/lib/detect-brew.sh" 2>/dev/null); then
        eval "$out"
        export BREW_BIN BREW_PREFIX
    fi
}

derive_nginx_conf_dir() {
    # 60-laravel-stack deploys a catchall nginx config. The destination differs
    # by OS; derive it here so deploy.sh (a fresh subshell) can see it via envsubst.
    case "$OS" in
        wsl|linux)
            NGINX_CONF_DIR="/etc/nginx/sites-enabled"
            ;;
        mac)
            if [[ -n "$BREW_PREFIX" ]]; then
                NGINX_CONF_DIR="$BREW_PREFIX/etc/nginx/servers"
            else
                NGINX_CONF_DIR=""
            fi
            ;;
        *)
            NGINX_CONF_DIR=""
            ;;
    esac
    export NGINX_CONF_DIR
}

detect_brew_if_mac
derive_nginx_conf_dir

if [[ "$OS" == "mac" ]]; then
    if [[ -n "$BREW_BIN" ]]; then
        info "brew found at $BREW_BIN (prefix $BREW_PREFIX)"
    else
        warn "brew not installed yet; topic 00-core will install it"
    fi
fi

# ---------- Interactive menu (default on TTYs; skipped for automation) ----------
# shellcheck disable=SC1091
source "$HERE/lib/menu.sh"
if should_show_menu; then
    if ensure_whiptail; then
        run_menu
    fi
fi

# ---------- Defaults for inherited vars ----------
export DOTFILES_REPO="${DOTFILES_REPO:-}"
export DOTFILES_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
export GIT_NAME="${GIT_NAME:-}"
export GIT_EMAIL="${GIT_EMAIL:-}"
export CODE_DIR="${CODE_DIR:-$HOME/code/web}"
export INCLUDE_DOCKER="${INCLUDE_DOCKER:-0}"
export INCLUDE_LARAVEL="${INCLUDE_LARAVEL:-0}"
export INCLUDE_REMOTE="${INCLUDE_REMOTE:-0}"
export INCLUDE_EDITOR="${INCLUDE_EDITOR:-0}"
export NO_COLOR="${NO_COLOR:-}"

# ---------- Sudo cache warmup ----------
# Bootstrap needs sudo for apt, systemctl, /etc/ writes in several topics.
# Prompt once upfront; subsequent sudo calls within the cache window
# (default 5-15min via /etc/sudoers timestamp_timeout) are silent.
# If the run takes longer than the cache, the next sudo call will re-prompt —
# acceptable trade-off vs. permanent NOPASSWD which is attack surface.
if [[ "${DRY_RUN:-}" != "1" ]]; then
    if ! sudo -v 2>/dev/null; then
        warn "sudo cache warmup failed (non-fatal — topics will prompt individually)"
    fi
fi

# ---------- Legacy cleanup (unconditional) ----------
# Pre-v2026-04-22 versions of topic 70-remote-access created a permanent
# NOPASSWD sudoers entry. That's attack surface we don't want. Clean it
# up on every bootstrap run — independent of opt-ins — so forks inherit
# the fix even if they don't re-run 70-remote-access.
if [[ "$OS" == "wsl" || "$OS" == "linux" ]] && [[ "${DRY_RUN:-}" != "1" ]]; then
    legacy_nopasswd="/etc/sudoers.d/10-${USER}-nopasswd"
    if [[ -f "$legacy_nopasswd" ]] || sudo test -f "$legacy_nopasswd" 2>/dev/null; then
        info "removing legacy NOPASSWD sudoers entry at $legacy_nopasswd"
        sudo rm -f "$legacy_nopasswd"
        ok "legacy NOPASSWD sudoers removed"
    fi
fi

# ---------- Collect topics ----------
# Portable across bash 3.2 (macOS default) and bash 4+: no `mapfile`, no
# GNU find `-printf`. Parameter expansion `${p##*/}` does basename without
# a fork, and the while-read loop fills the array in bash-3-friendly syntax.
all_topics=()
while IFS= read -r topic_dir; do
    all_topics+=("${topic_dir##*/}")
done < <(find "$HERE/topics" -mindepth 1 -maxdepth 1 -type d | sort)

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
        45-docker)        echo "INCLUDE_DOCKER" ;;
        60-laravel-stack) echo "INCLUDE_LARAVEL" ;;
        70-remote-access) echo "INCLUDE_REMOTE" ;;
        90-editor)        echo "INCLUDE_EDITOR" ;;
        *)                echo "" ;;
    esac
}

# ---------- Log file ----------
LOG="/tmp/dev-bootstrap-$OS-$(date +%Y%m%d-%H%M%S).log"
info "full log: $LOG"

# bash 3.2 (macOS default) + `set -u` is peculiar about empty arrays:
# `skip_list=(${SKIP_TOPICS:-})` leaves `skip_list` "declared but unbound"
# when the env var is empty, so any later `"${skip_list[@]}"` trips
# "unbound variable". Workaround: only build the array when the source
# var has content; otherwise stay explicit empty.
skip_list=()
only_list=()
if [[ -n "${SKIP_TOPICS:-}" ]]; then
    # shellcheck disable=SC2206
    skip_list=($SKIP_TOPICS)
fi
if [[ -n "${ONLY_TOPICS:-}" ]]; then
    # shellcheck disable=SC2206
    only_list=($ONLY_TOPICS)
fi

# Avoid `declare -a foo=() bar=() baz=()` one-liner — bash 3.2 parses it
# inconsistently. Split into 3 plain assignments.
passed=()
failed=()
skipped=()

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

    # Refresh brew detection + derived vars. Cheap, and catches the case where
    # 00-core (or any earlier topic) just installed brew on a fresh Mac.
    if [[ "$OS" == "mac" ]] && [[ -z "$BREW_BIN" ]]; then
        detect_brew_if_mac
        derive_nginx_conf_dir
        [[ -n "$BREW_BIN" ]] && info "brew now available at $BREW_BIN"
    fi

    passed+=("$topic")
}

for topic in "${all_topics[@]}"; do
    # Defensive `${arr[@]+"${arr[@]}"}` expansion — under bash 3.2 + set -u,
    # empty arrays passed via plain `"${arr[@]}"` raise "unbound variable".
    # The `+` form expands to nothing when the array is empty, to the full
    # contents otherwise. Works identically on bash 4+ / 5.x.
    if [[ "${#only_list[@]}" -gt 0 ]] && ! in_list "$topic" "${only_list[@]+"${only_list[@]}"}"; then
        continue
    fi
    if in_list "$topic" "${skip_list[@]+"${skip_list[@]}"}"; then
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
