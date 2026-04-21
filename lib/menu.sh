#!/usr/bin/env bash
# shellcheck shell=bash
# lib/menu.sh — interactive topic/config selector using whiptail.
# Source this file; do not execute directly.
#
# Exposes:
#   should_show_menu    — returns 0 when interactive menu should run
#   ensure_whiptail     — installs whiptail if missing; returns 1 if unavailable
#   run_menu            — shows the full menu flow and exports selected vars
#
# Exports set by run_menu (only when user selects them):
#   INCLUDE_LARAVEL, INCLUDE_REMOTE, INCLUDE_EDITOR
#   DOTFILES_REPO, GIT_NAME, GIT_EMAIL
#
# Depends on: $OS (from bootstrap.sh), $BREW_BIN (mac only), log.sh helpers.

should_show_menu() {
    # Explicit opt-out beats everything.
    [[ "${NON_INTERACTIVE:-0}" == "1" ]] && return 1
    [[ -n "${CI:-}" ]]                   && return 1

    # Any pre-configured control var means "automation mode" — respect it.
    [[ -n "${ONLY_TOPICS:-}" ]]          && return 1
    [[ "${INCLUDE_LARAVEL:-0}" == "1" ]] && return 1
    [[ "${INCLUDE_REMOTE:-0}" == "1" ]]  && return 1
    [[ "${INCLUDE_EDITOR:-0}" == "1" ]]  && return 1
    [[ -n "${DOTFILES_REPO:-}" ]]        && return 1

    # No TTY → can't show a menu (piped install, cron, etc).
    [[ -t 0 ]] && [[ -t 1 ]] || return 1

    return 0
}

ensure_whiptail() {
    if command -v whiptail >/dev/null 2>&1; then
        return 0
    fi

    info "whiptail not found — installing for interactive menu"
    case "$OS" in
        wsl|linux)
            if sudo apt-get install -y whiptail >/dev/null 2>&1; then
                ok "whiptail installed"
                return 0
            fi
            ;;
        mac)
            # On Homebrew, whiptail ships inside the `newt` formula.
            if [[ -n "${BREW_BIN:-}" ]] && "$BREW_BIN" install newt >/dev/null 2>&1; then
                ok "whiptail installed (via newt)"
                return 0
            fi
            ;;
    esac

    warn "could not install whiptail — set env vars manually or run with NON_INTERACTIVE=1"
    return 1
}

# whiptail exits non-zero when the user cancels (ESC or Cancel button).
# We treat any cancel as "user changed their mind" — exit the whole bootstrap
# cleanly so no partial state remains.
_menu_cancel() {
    warn "menu cancelled — no changes made"
    exit 0
}

# Detect whether an opt-in topic is already installed on this machine.
# Returns the string "ON" or "OFF" — used as the default state of each
# checklist item so re-runs pre-select what's already present (user just
# hits ENTER to keep current state + update).
#
# Heuristic per topic: look for a characteristic binary or directory that
# the installer produces. Kept permissive — if any signal is present, ON.
_topic_default_state() {
    case "$1" in
        laravel)
            if command -v php >/dev/null 2>&1 || command -v composer >/dev/null 2>&1; then
                echo ON
            else
                echo OFF
            fi
            ;;
        remote)
            # any of: tailscale CLI, syncthing binary, running sshd
            if command -v tailscale >/dev/null 2>&1 \
               || command -v syncthing >/dev/null 2>&1; then
                echo ON
            else
                echo OFF
            fi
            ;;
        editor)
            if [[ -x "$HOME/.local/bin/typora-wait" ]] \
               || command -v typora >/dev/null 2>&1 \
               || command -v glow >/dev/null 2>&1; then
                echo ON
            else
                echo OFF
            fi
            ;;
        dotfiles)
            local dir="${DOTFILES_DIR:-$HOME/dotfiles}"
            if [[ -d "$dir/.git" ]]; then
                echo ON
            else
                echo OFF
            fi
            ;;
        *)
            echo OFF
            ;;
    esac
}

run_menu() {
    banner "interactive setup"
    info "you can skip this menu anytime with: NON_INTERACTIVE=1 bash bootstrap.sh"
    info "or pre-seed via env vars (INCLUDE_LARAVEL=1, DOTFILES_REPO=..., etc)"
    echo

    # ---------- Screen 1: opt-in topics ----------
    # Defaults are computed per-topic from current machine state — re-runs
    # pre-select what's already installed so ENTER = "keep & update", which
    # is the common case. First run on a fresh machine still asks for everything.
    local choices
    choices=$(whiptail --title "dev-bootstrap :: opt-in topics" \
        --checklist \
        "Select optional topics to install (SPACE to toggle, ENTER to confirm).\nDefaults reflect what's already installed on this machine." \
        20 78 5 \
        "laravel"  "60-laravel-stack     — PHP 8.4 + nginx + MySQL 8"       "$(_topic_default_state laravel)" \
        "remote"   "70-remote-access     — SSH server + Tailscale + Syncthing" "$(_topic_default_state remote)" \
        "editor"   "90-editor            — typora-wait: open .md in Typora GUI from CLI" "$(_topic_default_state editor)" \
        "dotfiles" "95-dotfiles-personal — clone your personal dotfiles"    "$(_topic_default_state dotfiles)" \
        3>&1 1>&2 2>&3) || _menu_cancel

    local need_dotfiles=0
    # whiptail returns items quoted & space-separated: "laravel" "remote"
    # `local -a selected=()` (not just `local -a selected`) is needed for bash 3.2:
    # without an explicit empty-array initializer, `read -ra` into a still-undeclared
    # array name and subsequent `"${selected[@]}"` trip `set -u`.
    local -a selected=()
    read -ra selected <<< "${choices//\"/}"
    for choice in "${selected[@]+"${selected[@]}"}"; do
        case "$choice" in
            laravel)  export INCLUDE_LARAVEL=1 ;;
            remote)   export INCLUDE_REMOTE=1 ;;
            editor)   export INCLUDE_EDITOR=1 ;;
            dotfiles) need_dotfiles=1 ;;
        esac
    done

    # ---------- Screen 2: git identity (50-git is always-on) ----------
    # Precedence: env var > existing `git config --global` > prompt.
    # Topic 50-git also preserves existing values, but skipping the prompt
    # when they already exist makes the menu quieter.
    local existing_git_name="" existing_git_email=""
    if command -v git >/dev/null 2>&1; then
        existing_git_name=$(git config --global --get user.name 2>/dev/null || true)
        existing_git_email=$(git config --global --get user.email 2>/dev/null || true)
    fi

    if [[ -n "${GIT_NAME:-}" ]]; then
        : # provided via env — use as-is
    elif [[ -n "$existing_git_name" ]]; then
        info "keeping existing git user.name: $existing_git_name"
        GIT_NAME="$existing_git_name"
        export GIT_NAME
    else
        GIT_NAME=$(whiptail --title "50-git :: identity" \
            --inputbox "Git user.name (your full name):" \
            10 70 "" \
            3>&1 1>&2 2>&3) || _menu_cancel
        export GIT_NAME
    fi

    if [[ -n "${GIT_EMAIL:-}" ]]; then
        :
    elif [[ -n "$existing_git_email" ]]; then
        info "keeping existing git user.email: $existing_git_email"
        GIT_EMAIL="$existing_git_email"
        export GIT_EMAIL
    else
        GIT_EMAIL=$(whiptail --title "50-git :: identity" \
            --inputbox "Git user.email:" \
            10 70 "" \
            3>&1 1>&2 2>&3) || _menu_cancel
        export GIT_EMAIL
    fi

    # ---------- Screen 3: dotfiles repo URL (only if opted-in) ----------
    # Precedence: env var > existing clone's `git remote origin` > prompt.
    # Same pattern as git identity above — skips the prompt on re-run when
    # the dotfiles were already cloned.
    if [[ "$need_dotfiles" == "1" ]]; then
        local existing_dotfiles_repo=""
        local candidate_dir="${DOTFILES_DIR:-$HOME/dotfiles}"
        if command -v git >/dev/null 2>&1 && [[ -d "$candidate_dir/.git" ]]; then
            existing_dotfiles_repo=$(git -C "$candidate_dir" remote get-url origin 2>/dev/null || true)
        fi

        if [[ -n "${DOTFILES_REPO:-}" ]]; then
            :  # provided via env — use as-is
        elif [[ -n "$existing_dotfiles_repo" ]]; then
            info "keeping existing dotfiles remote: $existing_dotfiles_repo"
            DOTFILES_REPO="$existing_dotfiles_repo"
            DOTFILES_DIR="$candidate_dir"
            export DOTFILES_REPO DOTFILES_DIR
        else
            DOTFILES_REPO=$(whiptail --title "95-dotfiles-personal :: repo" \
                --inputbox \
"URL of your personal dotfiles repo.
Examples:
  git@github.com:youruser/dotfiles.git
  https://github.com/youruser/dotfiles.git
  file:///home/youruser/dotfiles   (local testing)" \
                14 78 "${DOTFILES_REPO:-}" \
                3>&1 1>&2 2>&3) || _menu_cancel

            if [[ -z "$DOTFILES_REPO" ]]; then
                warn "empty dotfiles URL — skipping 95-dotfiles-personal"
            else
                export DOTFILES_REPO

                # DOTFILES_DIR — where the repo will be cloned.
                # Pre-fill with expanded path so whiptail returns a valid absolute
                # path (tilde would NOT be expanded by the shell since it came
                # from user input, not a literal).
                DOTFILES_DIR=$(whiptail --title "95-dotfiles-personal :: clone path" \
                    --inputbox \
"Where to clone the dotfiles repo:" \
                    10 70 "${DOTFILES_DIR:-$HOME/dotfiles}" \
                    3>&1 1>&2 2>&3) || _menu_cancel
                export DOTFILES_DIR
            fi
        fi
    fi

    # ---------- Screen 3b: CODE_DIR (only if laravel stack opted in) ----------
    # Laravel topic uses CODE_DIR for the nginx catchall root. Other topics
    # don't read it, so only ask when it matters.
    if [[ "${INCLUDE_LARAVEL:-0}" == "1" ]]; then
        CODE_DIR=$(whiptail --title "60-laravel-stack :: projects root" \
            --inputbox \
"Root directory for Laravel projects. The nginx catchall serves
*.localhost from <CODE_DIR>/<project>/public." \
            12 70 "${CODE_DIR:-$HOME/code/web}" \
            3>&1 1>&2 2>&3) || _menu_cancel
        export CODE_DIR
    fi

    # ---------- Screen 4: confirm ----------
    local summary="Bootstrap will run with this configuration:\n\n"
    summary+="  Always-on topics:\n"
    summary+="    ✓ 00-core, 10-languages, 20-terminal-ux\n"
    summary+="    ✓ 30-shell, 40-tmux, 50-git, 80-claude-code\n\n"
    summary+="  Opt-in topics:\n"
    [[ "${INCLUDE_LARAVEL:-0}" == "1" ]] && summary+="    ✓ 60-laravel-stack\n"
    [[ "${INCLUDE_REMOTE:-0}"  == "1" ]] && summary+="    ✓ 70-remote-access\n"
    [[ "${INCLUDE_EDITOR:-0}"  == "1" ]] && summary+="    ✓ 90-editor\n"
    [[ -n "${DOTFILES_REPO:-}" ]]        && summary+="    ✓ 95-dotfiles-personal\n"
    if [[ "${INCLUDE_LARAVEL:-0}" != "1" && "${INCLUDE_REMOTE:-0}" != "1" \
       && "${INCLUDE_EDITOR:-0}"  != "1" && -z "${DOTFILES_REPO:-}" ]]; then
        summary+="    (none selected)\n"
    fi
    summary+="\n  Git identity:\n"
    summary+="    user.name  = $GIT_NAME\n"
    summary+="    user.email = $GIT_EMAIL\n"
    if [[ -n "${DOTFILES_REPO:-}" ]] || [[ "${INCLUDE_LARAVEL:-0}" == "1" ]]; then
        summary+="\n  Paths:\n"
        [[ -n "${DOTFILES_REPO:-}" ]]        && summary+="    dotfiles   = $DOTFILES_DIR  ← $DOTFILES_REPO\n"
        [[ "${INCLUDE_LARAVEL:-0}" == "1" ]] && summary+="    code       = $CODE_DIR\n"
    fi
    summary+="\nProceed?"

    whiptail --title "dev-bootstrap :: confirm" --yesno "$summary" 22 78 \
        || _menu_cancel

    ok "configuration captured — starting bootstrap"
}
