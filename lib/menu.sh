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
#   INCLUDE_DOCKER, INCLUDE_WEBSTACK, INCLUDE_REMOTE, INCLUDE_EDITOR
#   DOTFILES_REPO, GIT_NAME, GIT_EMAIL
#
# Depends on: $OS (from bootstrap.sh), $BREW_BIN (mac only), log.sh helpers.

should_show_menu() {
    # Explicit opt-out beats everything.
    [[ "${NON_INTERACTIVE:-0}" == "1" ]] && return 1
    [[ -n "${CI:-}" ]]                   && return 1

    # Any pre-configured control var means "automation mode" — respect it.
    # BUT: persisted state ($BOOTSTRAP_STATE_CONFIG) pre-fills these from
    # the last successful run — we DON'T want that to auto-suppress the
    # menu. Detect values coming from the state file and allow the menu
    # to re-prompt with them as defaults.
    [[ -n "${ONLY_TOPICS:-}" ]]           && return 1
    [[ "${STATE_LOADED:-0}" == "1" ]] && {
        # Values were loaded from state file — ignore them for the
        # "skip the menu" check. Menu will re-show with them as defaults.
        :
    } || {
        [[ "${INCLUDE_DOCKER:-0}"  == "1" ]]  && return 1
        [[ "${INCLUDE_WEBSTACK:-0}" == "1" ]]  && return 1
        [[ "${INCLUDE_REMOTE:-0}"  == "1" ]]  && return 1
        [[ "${INCLUDE_EDITOR:-0}"  == "1" ]]  && return 1
        [[ "${INCLUDE_MAILPIT:-0}" == "1" ]]  && return 1
        [[ "${INCLUDE_NGROK:-0}"   == "1" ]]  && return 1
        [[ "${INCLUDE_MSSQL:-0}"   == "1" ]]  && return 1
        [[ -n "${PHP_VERSIONS:-}" ]]          && return 1
        [[ -n "${DOTFILES_REPO:-}" ]]         && return 1
    }

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
        docker)
            # Both the CLI and either Colima (Mac) or the docker group
            # (Linux) are reasonable install signals. CLI alone covers
            # the 99% case.
            if command -v docker >/dev/null 2>&1; then
                echo ON
            else
                echo OFF
            fi
            ;;
        webstack)
            # The topic bundles php + nginx + mysql + redis + mkcert. Any of
            # the headline binaries present means the stack was likely set up
            # on this machine before — pre-check so re-runs default to
            # "update existing" rather than "install fresh".
            if command -v php >/dev/null 2>&1 \
               || command -v composer >/dev/null 2>&1 \
               || command -v nginx >/dev/null 2>&1 \
               || command -v mkcert >/dev/null 2>&1; then
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
    info "or pre-seed via env vars (INCLUDE_WEBSTACK=1, DOTFILES_REPO=..., etc)"
    echo

    # ---------- Screen 1: opt-in topics ----------
    # Defaults are computed per-topic from current machine state — re-runs
    # pre-select what's already installed so ENTER = "keep & update", which
    # is the common case. First run on a fresh machine still asks for everything.
    local choices
    # Descriptions kept short enough to fit a single line at 85-col width.
    # The `NN-topic` prefix stays (users learn the topic numbering through
    # the menu and refer to it later in READMEs + commits). Widths tuned
    # so the longest ("95-dotfiles-personal: your private dotfiles") fits
    # without wrap on 85-col terminals.
    choices=$(whiptail --title "dev-bootstrap :: opt-in topics" \
        --checklist \
        "Select optional topics to install (SPACE toggles, ENTER confirms).\nDefaults reflect what's already installed on this machine." \
        20 85 6 \
        "docker"   "45-docker: Docker Engine (WSL) / Colima (Mac)"    "$(_topic_default_state docker)" \
        "webstack" "60-web-stack: multi-PHP + nginx + MySQL + mkcert + reverse proxy" "$(_topic_default_state webstack)" \
        "remote"   "70-remote-access: SSH + Tailscale + Syncthing"    "$(_topic_default_state remote)" \
        "editor"   "90-editor: typora-wait (open .md from CLI)"       "$(_topic_default_state editor)" \
        "dotfiles" "95-dotfiles-personal: your private dotfiles"      "$(_topic_default_state dotfiles)" \
        3>&1 1>&2 2>&3) || _menu_cancel

    local need_dotfiles=0
    # whiptail returns items quoted & space-separated: "webstack" "remote"
    # `local -a selected=()` (not just `local -a selected`) is needed for bash 3.2:
    # without an explicit empty-array initializer, `read -ra` into a still-undeclared
    # array name and subsequent `"${selected[@]}"` trip `set -u`.
    local -a selected=()
    read -ra selected <<< "${choices//\"/}"
    for choice in "${selected[@]+"${selected[@]}"}"; do
        case "$choice" in
            docker)   export INCLUDE_DOCKER=1 ;;
            webstack) export INCLUDE_WEBSTACK=1 ;;
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
            # Two-path prompt: (a) create new fork from a public template via
            # `gh repo create --template`, or (b) provide an existing URL.
            # Path (a) is the on-ramp for first-time users — they don't have to
            # leave the terminal to fork the template manually on github.com.
            # Path (b) handles existing repos, local testing (`file://`), or
            # forks-of-forks where the template default doesn't apply.
            #
            # Both paths set DOTFILES_REPO + DOTFILES_DIR. Path (a) ALSO exports
            # CREATE_DOTFILES_FROM_TEMPLATE=1 + the inputs for `gh repo create`,
            # which 95-dotfiles-personal/install.sh consumes (gh CLI is ready
            # by then — installed by 05-identity earlier in the topic order).
            if whiptail --title "95-dotfiles-personal :: source" \
                --yesno \
"Create your dotfiles repo NOW from a GitHub template?

Yes  →  prompt for owner/template, run \`gh repo create --template …\`,
        clone, then run install.sh of the clone.
No   →  point me at an existing dotfiles repo URL." \
                12 78 3>&1 1>&2 2>&3; then

                local _template_default="${DOTFILES_TEMPLATE_REPO:-henryavila/dotfiles-template}"
                DOTFILES_TEMPLATE_REPO=$(whiptail --title "create from template :: source template" \
                    --inputbox \
"Template repo (owner/name).
Press ENTER to accept the default skeleton; override for forks-of-forks
or enterprise templates." \
                    11 78 "$_template_default" \
                    3>&1 1>&2 2>&3) || _menu_cancel

                # Default new owner = system $USER (matches a common case where
                # local user matches the GitHub username). User can override.
                local _new_owner=$(whiptail --title "create from template :: new repo owner" \
                    --inputbox \
"Your GitHub username (or organization). The new repo will be created
as <owner>/<name>." \
                    10 70 "${DOTFILES_NEW_REPO_OWNER:-$USER}" \
                    3>&1 1>&2 2>&3) || _menu_cancel

                local _new_name=$(whiptail --title "create from template :: new repo name" \
                    --inputbox \
"Name for the new repo:" \
                    10 70 "${DOTFILES_NEW_REPO_NAME:-dotfiles}" \
                    3>&1 1>&2 2>&3) || _menu_cancel

                # Default = private. The recommendation is private even for
                # solo devs because dotfiles often pick up secrets/identity.
                local _new_private=1
                if ! whiptail --title "create from template :: visibility" \
                    --yesno "Make the new repo PRIVATE? (recommended)" \
                    8 60 3>&1 1>&2 2>&3; then
                    _new_private=0
                fi

                DOTFILES_NEW_REPO_OWNER="$_new_owner"
                DOTFILES_NEW_REPO_NAME="$_new_name"
                DOTFILES_NEW_REPO_PRIVATE="$_new_private"
                CREATE_DOTFILES_FROM_TEMPLATE=1
                DOTFILES_REPO="git@github.com:${_new_owner}/${_new_name}.git"
                DOTFILES_DIR="${DOTFILES_DIR:-$HOME/${_new_name}}"
                export CREATE_DOTFILES_FROM_TEMPLATE DOTFILES_TEMPLATE_REPO
                export DOTFILES_NEW_REPO_OWNER DOTFILES_NEW_REPO_NAME DOTFILES_NEW_REPO_PRIVATE
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
    fi

    # ---------- Screen 3b–3e: laravel stack configuration ----------
    # Only prompts when the user opted into 60-web-stack. Each screen
    # exports its selection so 10-languages + 60-web-stack read the
    # same values that the menu gathered.
    if [[ "${INCLUDE_WEBSTACK:-0}" == "1" ]]; then
        # --- 3b · CODE_DIR ---
        CODE_DIR=$(whiptail --title "60-web-stack :: projects root" \
            --inputbox \
"Root directory for your web projects.
Every subdir becomes a <name>.localhost site automatically:
  - WSL/Linux: nginx catchall serves <CODE_DIR>/<project>/public
  - Mac:       Valet parks this dir (TLD aligned to .localhost)

Same URL on both platforms — https://<name>.localhost." \
            14 72 "${CODE_DIR:-$HOME/code/web}" \
            3>&1 1>&2 2>&3) || _menu_cancel
        export CODE_DIR

        # --- 3c · PHP versions (multi-select) ---
        # Pulls the list from the single source of truth so adding a new
        # version to php-versions.conf auto-propagates to the menu.
        # Label carries the install state so users can tell at a glance
        # what's on disk vs. what they're about to add.
        local versions_file
        versions_file="$(dirname "${BASH_SOURCE[0]}")/../topics/10-languages/data/php-versions.conf"
        local -a php_checklist_items=()
        if [[ -f "$versions_file" ]]; then
            while IFS= read -r ver; do
                local state="OFF" label_tag=""
                if command -v "php${ver}" >/dev/null 2>&1 \
                   || [[ -x "/usr/bin/php${ver}" ]] \
                   || brew list --formula "php@${ver}" >/dev/null 2>&1 2>/dev/null; then
                    state="ON"
                    label_tag="(installed)"
                else
                    label_tag="(not installed yet)"
                fi
                php_checklist_items+=("$ver" "PHP $ver  $label_tag" "$state")
            done < <(grep -vE '^\s*(#|$)' "$versions_file" | sort -V)
        fi
        # If nothing looks installed yet, pre-select the last (latest) version
        # so fresh machines get a sensible default.
        if [[ "${#php_checklist_items[@]}" -ge 3 ]]; then
            local any_on=0
            for ((i=2; i<${#php_checklist_items[@]}; i+=3)); do
                [[ "${php_checklist_items[$i]}" == "ON" ]] && { any_on=1; break; }
            done
            if [[ "$any_on" == "0" ]]; then
                # Turn on the last one (highest version after sort -V)
                php_checklist_items[${#php_checklist_items[@]}-1]="ON"
            fi
        fi

        local php_choices
        php_choices=$(whiptail --title "60-web-stack :: PHP versions" \
            --checklist \
"Pick which PHP versions to have on this machine.
The LAST one checked becomes the CLI / Composer / FPM default
(switch later with: php-use <version>).

  Check    = install if missing, keep if already installed (idempotent)
  Uncheck  = skip during this run. DOES NOT UNINSTALL anything already
             present — to remove, use 'sudo apt-get remove php8.X*' on
             Linux or 'brew uninstall php@X.Y' on Mac." \
            20 78 6 \
            "${php_checklist_items[@]}" \
            3>&1 1>&2 2>&3) || _menu_cancel

        # whiptail returns quoted space-separated values: "8.4" "8.5"
        local -a php_selected=()
        read -ra php_selected <<< "${php_choices//\"/}"
        if [[ "${#php_selected[@]}" -gt 0 ]]; then
            # Sort so PHP_DEFAULT = last (highest) is deterministic
            PHP_VERSIONS="$(printf '%s\n' "${php_selected[@]}" | sort -V | tr '\n' ' ' | sed 's/ $//')"
            PHP_DEFAULT="$(echo "$PHP_VERSIONS" | tr ' ' '\n' | tail -1)"
            export PHP_VERSIONS PHP_DEFAULT
        else
            warn "no PHP version selected — topics 10-languages + 60-web-stack will pick defaults"
        fi

        # --- 3d · Laravel extras (multi-select) ---
        # State detection for extras follows the same pattern as PHP
        # versions: label carries "(installed)" / "(not installed yet)"
        # so the user isn't guessing. Detection is best-effort (cheap
        # binary + extension checks) — false positives/negatives are OK
        # because the installers themselves are idempotent.
        local mp_state ng_state fe_state ms_state
        local mp_tag ng_tag fe_tag ms_tag

        command -v mailpit >/dev/null 2>&1 \
            && { mp_state=ON;  mp_tag="(installed)"; } \
            || { mp_state=ON;  mp_tag="(not installed yet)"; }

        command -v ngrok >/dev/null 2>&1 \
            && { ng_state=ON;  ng_tag="(installed)"; } \
            || { ng_state=OFF; ng_tag="(not installed yet)"; }

        # Frontend catchall = the nginx site config (checked by file presence)
        if [[ -e /etc/nginx/sites-enabled/catchall-proxy.conf ]] \
           || [[ -e "${BREW_PREFIX:-/opt/homebrew}/etc/nginx/servers/catchall-proxy.conf" ]]; then
            fe_state=ON;  fe_tag="(already set up)"
        else
            fe_state=ON;  fe_tag="(not set up yet)"
        fi

        php -m 2>/dev/null | grep -qi sqlsrv \
            && { ms_state=ON;  ms_tag="(installed)"; } \
            || { ms_state=OFF; ms_tag="(not installed yet)"; }

        local extras_choices
        extras_choices=$(whiptail --title "60-web-stack :: optional extras" \
            --checklist \
"Add-ons to the Laravel stack.

  Check    = install / configure if missing, keep if already there
  Uncheck  = skip this run. Nothing is uninstalled — remove manually
             with apt/brew if you really want it gone.

MSSQL takes ~2 min (auto-accepts Microsoft's EULA via ACCEPT_EULA=Y)." \
            20 82 4 \
            "mailpit"  "local mail catcher, SMTP :1025 + UI :8025    $mp_tag"  "$mp_state" \
            "ngrok"    "public tunnel (share-project wrapper)        $ng_tag"  "$ng_state" \
            "frontend" "*.front.localhost proxy catchall             $fe_tag"  "$fe_state" \
            "mssql"    "SQL Server ODBC + sqlsrv/pdo_sqlsrv PECL     $ms_tag"  "$ms_state" \
            3>&1 1>&2 2>&3) || _menu_cancel

        local -a extras_selected=()
        read -ra extras_selected <<< "${extras_choices//\"/}"
        for choice in "${extras_selected[@]+"${extras_selected[@]}"}"; do
            case "$choice" in
                mailpit)  export INCLUDE_MAILPIT=1 ;;
                ngrok)    export INCLUDE_NGROK=1 ;;
                frontend) export INCLUDE_FRONTEND_PROXY=1 ;;
                mssql)    export INCLUDE_MSSQL=1 ;;
            esac
        done

        # --- 3e · ngrok authtoken ---
        # ngrok is the one extra with no CLI OAuth flow — user pastes a
        # token from the dashboard. Ask once, persist to secrets.env
        # (0600), and every future bootstrap on this host skips the
        # prompt. Skipped outright if the token is already known via
        # env or secrets.env, or if ngrok config already has one.
        if [[ "${INCLUDE_NGROK:-0}" == "1" ]] \
           && ! secrets_has NGROK_AUTHTOKEN \
           && ! ngrok config check >/dev/null 2>&1; then
            local ngrok_token=""
            ngrok_token=$(whiptail --title "60-web-stack :: ngrok authtoken" \
                --passwordbox \
"Paste your ngrok authtoken from
  https://dashboard.ngrok.com/get-started/your-authtoken

Stored at $BOOTSTRAP_SECRETS_FILE (mode 0600).
Leave empty to skip — you can set it later via:
  ngrok config add-authtoken <token>
or re-run bootstrap with NGROK_AUTHTOKEN=<token>." \
                16 78 "" \
                3>&1 1>&2 2>&3) || ngrok_token=""

            if [[ -n "$ngrok_token" ]]; then
                secrets_set NGROK_AUTHTOKEN "$ngrok_token"
                export NGROK_AUTHTOKEN="$ngrok_token"
                ok "ngrok authtoken captured → $BOOTSTRAP_SECRETS_FILE (0600)"
            fi
            unset ngrok_token
        fi
    fi

    # ---------- Screen 4: confirm ----------
    local summary="Bootstrap will run with this configuration:\n\n"
    summary+="  Always-on topics:\n"
    summary+="    ✓ 00-core, 10-languages, 20-terminal-ux\n"
    summary+="    ✓ 30-shell, 40-tmux, 50-git, 80-claude-code\n\n"
    summary+="  Opt-in topics:\n"
    [[ "${INCLUDE_DOCKER:-0}"  == "1" ]] && summary+="    ✓ 45-docker\n"
    [[ "${INCLUDE_WEBSTACK:-0}" == "1" ]] && summary+="    ✓ 60-web-stack\n"
    [[ "${INCLUDE_REMOTE:-0}"  == "1" ]] && summary+="    ✓ 70-remote-access\n"
    [[ "${INCLUDE_EDITOR:-0}"  == "1" ]] && summary+="    ✓ 90-editor\n"
    [[ -n "${DOTFILES_REPO:-}" ]]        && summary+="    ✓ 95-dotfiles-personal\n"
    if [[ "${INCLUDE_DOCKER:-0}"  != "1" && "${INCLUDE_WEBSTACK:-0}" != "1" \
       && "${INCLUDE_REMOTE:-0}"  != "1" && "${INCLUDE_EDITOR:-0}"  != "1" \
       && -z "${DOTFILES_REPO:-}" ]]; then
        summary+="    (none selected)\n"
    fi
    summary+="\n  Git identity:\n"
    summary+="    user.name  = $GIT_NAME\n"
    summary+="    user.email = $GIT_EMAIL\n"
    if [[ -n "${DOTFILES_REPO:-}" ]] || [[ "${INCLUDE_WEBSTACK:-0}" == "1" ]]; then
        summary+="\n  Paths:\n"
        [[ -n "${DOTFILES_REPO:-}" ]]        && summary+="    dotfiles   = $DOTFILES_DIR  ← $DOTFILES_REPO\n"
        [[ "${INCLUDE_WEBSTACK:-0}" == "1" ]] && summary+="    code       = $CODE_DIR\n"
    fi
    summary+="\nProceed?"

    whiptail --title "dev-bootstrap :: confirm" --yesno "$summary" 22 78 \
        || _menu_cancel

    ok "configuration captured — starting bootstrap"

    # Persist the answers so next run pre-fills the same values instead
    # of falling back to first-run defaults. Written to
    # $BOOTSTRAP_STATE_CONFIG (default: ~/.local/state/dev-bootstrap/config.env).
    # Plain shell-sourceable file — readable, diff-able, editable by hand.
    # Delete to reset.
    _persist_menu_state
}

_persist_menu_state() {
    # Only if bootstrap.sh set up the path. When menu is sourced in a
    # different context (tests, manual invocation), this is a no-op.
    [[ -z "${BOOTSTRAP_STATE_CONFIG:-}" ]] && return 0
    mkdir -p "$(dirname "$BOOTSTRAP_STATE_CONFIG")"
    # Write atomically: tmp file + rename so a half-written state file
    # can't break the next bootstrap's `source`.
    local tmp="${BOOTSTRAP_STATE_CONFIG}.tmp"
    {
        echo "# dev-bootstrap — last menu selections. Auto-generated."
        echo "# Edit by hand or delete this file to reset defaults."
        echo "# Env vars set at runtime still win over whatever is here."
        echo
        [[ -n "${CODE_DIR:-}" ]]             && printf 'export CODE_DIR=%q\n' "$CODE_DIR"
        [[ -n "${DOTFILES_REPO:-}" ]]        && printf 'export DOTFILES_REPO=%q\n' "$DOTFILES_REPO"
        [[ -n "${DOTFILES_DIR:-}" ]]         && printf 'export DOTFILES_DIR=%q\n' "$DOTFILES_DIR"
        [[ -n "${PHP_VERSIONS:-}" ]]         && printf 'export PHP_VERSIONS=%q\n' "$PHP_VERSIONS"
        [[ -n "${PHP_DEFAULT:-}" ]]          && printf 'export PHP_DEFAULT=%q\n' "$PHP_DEFAULT"
        [[ -n "${DEV_DEFAULT_PORT:-}" ]]     && printf 'export DEV_DEFAULT_PORT=%q\n' "$DEV_DEFAULT_PORT"
        # INCLUDE_* — only persist when on; absence = re-asked next run.
        # Rationale: user unchecking an opt-in should not re-offer it
        # as "on by default" next time (they said no). Our menu already
        # pre-selects based on installed state for most extras, so the
        # non-persisted "off" case still gets sensible defaults.
        [[ "${INCLUDE_DOCKER:-0}"  == "1" ]] && echo 'export INCLUDE_DOCKER=1'
        [[ "${INCLUDE_WEBSTACK:-0}" == "1" ]] && echo 'export INCLUDE_WEBSTACK=1'
        [[ "${INCLUDE_REMOTE:-0}"  == "1" ]] && echo 'export INCLUDE_REMOTE=1'
        [[ "${INCLUDE_EDITOR:-0}"  == "1" ]] && echo 'export INCLUDE_EDITOR=1'
        [[ "${INCLUDE_MAILPIT:-0}" == "1" ]] && echo 'export INCLUDE_MAILPIT=1'
        [[ "${INCLUDE_NGROK:-0}"   == "1" ]] && echo 'export INCLUDE_NGROK=1'
        [[ "${INCLUDE_MSSQL:-0}"   == "1" ]] && echo 'export INCLUDE_MSSQL=1'
        [[ "${INCLUDE_FRONTEND_PROXY:-0}" == "1" ]] && echo 'export INCLUDE_FRONTEND_PROXY=1'
    } > "$tmp"
    mv -f "$tmp" "$BOOTSTRAP_STATE_CONFIG"
}
