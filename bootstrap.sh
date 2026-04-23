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
#   INCLUDE_WEBSTACK=1  enables 60-web-stack  (legacy alias: INCLUDE_LARAVEL=1)
#   INCLUDE_REMOTE=1    enables 70-remote-access
#   INCLUDE_EDITOR=1    enables 90-editor
#   PHP_VERSIONS        space-separated list (e.g. "8.4 8.5"); last = default
#                       (if unset: all versions listed in
#                       topics/10-languages/data/php-versions.conf)
#   PHP_DEFAULT         override which version becomes PATH / FPM / composer default
#   INCLUDE_MAILPIT=1   installs mailpit (SMTP :1025, UI :8025) inside 60-web-stack
#   INCLUDE_NGROK=1     installs ngrok + share-project wrapper
#   INCLUDE_MSSQL=1     installs Microsoft SQL Server ODBC driver + sqlsrv/pdo_sqlsrv
#                       PECL extensions (ACCEPT_EULA=Y auto-set)
#   NGROK_AUTHTOKEN     ngrok token to auto-configure during install
#                       (if unset, the menu prompts once + persists to
#                       ~/.local/state/dev-bootstrap/secrets.env, mode 0600)
#   CHSH_AUTO=0         skip the auto `sudo chsh` attempt in 20-terminal-ux
#                       (default 1 — tries to set zsh as default login
#                       shell using the cached sudo ticket; falls back
#                       to an advisory if refused)
#   DEV_DEFAULT_PORT    default port for *.front.localhost proxy (default 3000)
#   FORCE_VALET_INSTALL=1  (Mac only) force re-run `valet install` even when
#                       it appears already configured. Useful after macOS
#                       upgrades that rotate dnsmasq config or when
#                       recovering from a corrupted Valet state.
#   NO_COLOR=1          disable colored output (auto if not a TTY)
#
# Usage: bash bootstrap.sh [--help] [--non-interactive]

set -euo pipefail

# Minimal shells (docker run, `su -`, some cron contexts, `env -i`) leave $USER
# unset even when the effective UID is a real account. `id -un` always works.
# Exported so every topic + envsubst in lib/deploy.sh sees a consistent value.
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

# Collect follow-up actions from every topic into a single file so we
# can render one consolidated summary at the end (vs. scattering `!`
# warnings across hundreds of lines of topic output). Topics invoke
# `followup <severity> <msg>` from lib/log.sh — the severity bucket
# (critical / manual / info) drives how the summary renders.
export BOOTSTRAP_FOLLOWUP_FILE="$(mktemp -t dev-bootstrap-followup.XXXXXX 2>/dev/null || mktemp)"
trap 'rm -f "${BOOTSTRAP_FOLLOWUP_FILE:-}"' EXIT

# Persistent state across bootstrap runs — stores last-used values so
# the interactive menu can pre-fill fields (CODE_DIR, PHP_VERSIONS,
# opt-in flags, etc.) on re-runs instead of always showing the defaults.
# Format: shell-sourceable `export KEY=value` lines — readable, diff-able,
# editable by hand. Delete the file to reset to defaults.
export BOOTSTRAP_STATE_DIR="$HOME/.local/state/dev-bootstrap"
export BOOTSTRAP_STATE_CONFIG="$BOOTSTRAP_STATE_DIR/config.env"
mkdir -p "$BOOTSTRAP_STATE_DIR"
if [[ -f "$BOOTSTRAP_STATE_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$BOOTSTRAP_STATE_CONFIG"
    # Signal to should_show_menu that the control vars came from state,
    # not from a user-set env — state-loaded values must not suppress
    # the interactive menu (we want it to re-show with them as defaults).
    export STATE_LOADED=1
fi

# ─── Legacy alias: INCLUDE_LARAVEL=1 → INCLUDE_WEBSTACK=1 ───────────────
# The topic was renamed from 60-laravel-stack to 60-web-stack (it installs
# a full web dev stack: nginx + reverse proxy + MySQL + Redis + mkcert +
# PHP-FPM, of which Laravel is just one consumer). The env var + state
# file keys are canonically INCLUDE_WEBSTACK now, but we honor the
# previous name indefinitely so automation scripts, CI configs, and
# persisted state files from older runs keep working unchanged.
if [[ -n "${INCLUDE_LARAVEL:-}" ]] && [[ -z "${INCLUDE_WEBSTACK:-}" ]]; then
    export INCLUDE_WEBSTACK="$INCLUDE_LARAVEL"
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# shellcheck disable=SC1091
source "$HERE/lib/log.sh"

# ─── Secrets (tokens) ───────────────────────────────────────────────
# Separate from config.env because of different mode (0600 vs 0644)
# and different blast-radius semantics. Sourced BEFORE the menu so
# `secrets_has NGROK_AUTHTOKEN` can gate whether the menu prompts
# for a token, and BEFORE topics run so installers just read env.
# See lib/secrets.sh for the allowed/forbidden key taxonomy.
# shellcheck disable=SC1091
source "$HERE/lib/secrets.sh"
secrets_load || warn "secrets file present but could not be sourced — continuing without it"

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
  60-web-stack          INCLUDE_WEBSTACK=1   (legacy: INCLUDE_LARAVEL=1 still accepted)
  70-remote-access      INCLUDE_REMOTE=1
  90-editor             INCLUDE_EDITOR=1
  95-dotfiles-personal  DOTFILES_REPO=<url>

Other env vars:
  GIT_NAME, GIT_EMAIL, CODE_DIR, DOTFILES_DIR, NO_COLOR
  GPG_SIGN=1 [+ GPG_KEY_ID=<id>]  enable GPG commit signing in 50-git
  PHP_VERSIONS="8.4 8.5" [+ PHP_DEFAULT=8.5]  multi-PHP install (60-web-stack)
  INCLUDE_WEBSTACK=1              opt-in for 60-web-stack
                                  (accepted: INCLUDE_LARAVEL=1 for backward compat)
  INCLUDE_MAILPIT=1, INCLUDE_NGROK=1 [+ NGROK_AUTHTOKEN=], INCLUDE_MSSQL=1
  DEV_DEFAULT_PORT=3000           default port for *.front.localhost proxy

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
    # 60-web-stack deploys multiple nginx files that reference these
    # paths via envsubst. deploy.sh runs in a fresh subshell from the
    # bootstrap parent (NOT from install.*.sh), so exports inside the
    # installer don't propagate here. Every path the DEPLOY file mentions
    # must be derived + exported in the bootstrap shell itself.
    case "$OS" in
        wsl|linux)
            NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
            NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
            NGINX_SNIPPET_DIR="/etc/nginx/snippets"
            NGINX_MAP_DIR="/etc/nginx/conf.d"
            CERT_DIR="/etc/nginx/certs"
            ;;
        mac)
            if [[ -n "$BREW_PREFIX" ]]; then
                NGINX_AVAILABLE_DIR="$BREW_PREFIX/etc/nginx/servers-available"
                NGINX_ENABLED_DIR="$BREW_PREFIX/etc/nginx/servers"
                NGINX_SNIPPET_DIR="$BREW_PREFIX/etc/nginx/snippets"
                NGINX_MAP_DIR="$BREW_PREFIX/etc/nginx/conf.d"
                CERT_DIR="$BREW_PREFIX/etc/nginx/certs"
            else
                NGINX_AVAILABLE_DIR="" NGINX_ENABLED_DIR=""
                NGINX_SNIPPET_DIR=""   NGINX_MAP_DIR=""
                CERT_DIR=""
            fi
            ;;
        *)
            NGINX_AVAILABLE_DIR="" NGINX_ENABLED_DIR=""
            NGINX_SNIPPET_DIR=""   NGINX_MAP_DIR=""
            CERT_DIR=""
            ;;
    esac
    # Back-compat alias (templates that still use $NGINX_CONF_DIR — same
    # semantic as sites-enabled for historical reasons).
    NGINX_CONF_DIR="$NGINX_ENABLED_DIR"
    export NGINX_CONF_DIR NGINX_AVAILABLE_DIR NGINX_ENABLED_DIR \
           NGINX_SNIPPET_DIR NGINX_MAP_DIR CERT_DIR

    # DEV_DEFAULT_PORT is used by catchall-proxy.conf; default if unset
    # so envsubst never leaves a literal ${DEV_DEFAULT_PORT} in the file.
    : "${DEV_DEFAULT_PORT:=3000}"
    export DEV_DEFAULT_PORT
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
export INCLUDE_WEBSTACK="${INCLUDE_WEBSTACK:-0}"
# Keep legacy name exported too so any external integration / script that
# reads INCLUDE_LARAVEL continues to observe the canonical value.
export INCLUDE_LARAVEL="$INCLUDE_WEBSTACK"
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
        60-web-stack) echo "INCLUDE_WEBSTACK" ;;
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

# Consolidated follow-up summary — one place to see every manual step
# + every critical gap that survived the run. Topics write these via
# `followup <severity> <msg>` from lib/log.sh; render_followup_summary
# reads the collected file and renders grouped by severity.
render_followup_summary

if [[ "${#failed[@]}" -gt 0 ]]; then
    fail "some topics failed — see $LOG"
    exit 1
fi

ok "done"
