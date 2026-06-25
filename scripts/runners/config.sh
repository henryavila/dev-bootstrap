#!/usr/bin/env bash
# scripts/runners/config.sh — edit personal mesh-identity config files from deploy.map.
#
# Usage:
#   mesh config [term]          Pick/edit a deployed personal config.
#   mesh config list [term]     List deploy.map configs, optionally filtered.
#
# Flow: choose source -> edit it -> show git diff for that source -> run the
# identity install script so deploy.map updates the rendered destination files.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/log.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/env.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/deploy.sh"

ID_DIR="${MESH_CONFIG_IDENTITY_DIR:-$MESH_IDENTITY_DIR}"
MAP="$ID_DIR/deploy.map"
INSTALL_SH="$ID_DIR/install.sh"

LIST=0
NO_INSTALL=0
NO_DIFF=0
TERM_ARG=""

_config_usage() {
    cat <<'EOF'
Usage:
  mesh config [term]              Edit a personal config from mesh-identity/deploy.map
  mesh config list [term]         List source files and deployed destinations
  mesh config [term] --no-install Edit + diff, but skip the deploy step
  mesh config [term] --no-diff    Edit + deploy without printing git diff

Examples:
  mesh config aliases
  mesh config zsh
  mesh config list claude
EOF
}

_config_die() {
    log_error "config: $*"
    exit 1
}

_config_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_config_label() {
    case "$1" in
        ssh/config)                                printf 'SSH config' ;;
        ssh/authorized_keys)                       printf 'SSH authorized keys' ;;
        git/gitconfig.local)                       printf 'Git local config' ;;
        git/gitignore_global)                      printf 'Git global ignore' ;;
        shell/bashrc.local)                        printf 'Bash local' ;;
        shell/zshrc.local)                         printf 'Zsh local' ;;
        shell/p10k.zsh)                            printf 'Powerlevel10k prompt' ;;
        shell/aliases.sh)                          printf 'Personal aliases' ;;
        config/htoprc)                             printf 'htop' ;;
        config/lazygit/config.yml)                 printf 'Lazygit' ;;
        config/btop/btop.conf)                     printf 'btop config' ;;
        config/btop/themes/*)                      printf 'btop theme' ;;
        config/eza/theme.yml)                      printf 'eza theme' ;;
        config/nvim/init.lua)                      printf 'Neovim init' ;;
        codex/config.toml)                         printf 'Codex config' ;;
        claude/manifest/mcps-user.sh)              printf 'Claude MCP user manifest' ;;
        claude/manifest/shared.json)               printf 'Claude shared manifest' ;;
        claude/stignore/claude-config.stignore)    printf 'Claude config ignore' ;;
        claude/stignore/claude-mem.stignore)       printf 'Claude memory ignore' ;;
        claude/scripts/claude-snapshot.sh)         printf 'Claude snapshot command' ;;
        claude/scripts/claude-replicate.sh)        printf 'Claude replicate command' ;;
        claude/scripts/claude-promote.sh)          printf 'Claude promote command' ;;
        claude/scripts/sync/claude-mem-sync.sh)    printf 'Claude memory sync command' ;;
        config/claudebar/config.toml)              printf 'Claudebar config' ;;
        config/mesh-status.conf.example)           printf 'Mesh status config seed' ;;
        *)                                         printf '%s' "$1" ;;
    esac
}

_config_require_map() {
    [[ -r "$MAP" ]] || _config_die "deploy.map not readable at $MAP"
}

# Emit rows as: label<TAB>src<TAB>destinations<TAB>modes
# Multiple deploy.map rows with the same source are collapsed, so shell/aliases.sh
# appears once even though it deploys to both bash and zsh fragments.
_config_rows() {
    _config_require_map
    deploy_map_emit "$MAP" \
        | awk -F'|' '
            {
                src=$1; dst=$2; mode=$3;
                if (mode == "") mode = "overwrite";
                if (!(src in seen)) {
                    seen[src] = 1;
                    order[++n] = src;
                    dsts[src] = dst;
                    modes[src] = mode;
                } else {
                    dsts[src] = dsts[src] ", " dst;
                    if (index("," modes[src] ",", "," mode ",") == 0) {
                        modes[src] = modes[src] ", " mode;
                    }
                }
            }
            END {
                for (i = 1; i <= n; i++) {
                    src = order[i];
                    print src "\t" dsts[src] "\t" modes[src];
                }
            }
        ' \
        | while IFS=$'\t' read -r src dsts modes; do
            [[ -n "$src" ]] || continue
            printf '%s\t%s\t%s\t%s\n' "$(_config_label "$src")" "$src" "$dsts" "$modes"
        done
}

_config_filter() {
    local term="$1" lc label src dsts modes hay
    lc="$(_config_lower "$term")"
    _config_rows | while IFS=$'\t' read -r label src dsts modes; do
        if [[ -z "$lc" ]]; then
            printf '%s\t%s\t%s\t%s\n' "$label" "$src" "$dsts" "$modes"
            continue
        fi
        hay="$(_config_lower "$label $src $dsts $modes")"
        case "$hay" in
            *"$lc"*) printf '%s\t%s\t%s\t%s\n' "$label" "$src" "$dsts" "$modes" ;;
        esac
    done
}

_config_list() {
    local term="$1" rows line label src dsts modes
    rows="$(_config_filter "$term")"
    [[ -n "$rows" ]] || _config_die "no config matches '${term:-<all>}'"
    printf '%-30s  %-38s  %s\n' "Name" "Source" "Destinations"
    printf '%-30s  %-38s  %s\n' "----" "------" "------------"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=$'\t' read -r label src dsts modes <<<"$line"
        printf '%-30s  %-38s  %s\n' "$label" "$src" "$dsts"
    done <<<"$rows"
}

_config_pick_bash() {
    local file="$1" n=0 sel line label src dsts modes
    local -a lines
    lines=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && lines+=("$line")
    done < "$file"
    (( ${#lines[@]} > 0 )) || return 1
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        _config_die "multiple matches; run 'mesh config list ${TERM_ARG}' and pass a more specific term"
    fi

    for line in "${lines[@]}"; do
        n=$((n + 1))
        IFS=$'\t' read -r label src dsts modes <<<"$line"
        printf '  %2d) %-30s %-34s %s\n' "$n" "$label" "$src" "$dsts" >/dev/tty
    done
    printf 'config> pick a number (q = cancel): ' >/dev/tty
    IFS= read -r sel </dev/tty || return 1
    [[ "$sel" == q || -z "$sel" ]] && return 130
    if [[ ! "$sel" =~ ^[0-9]+$ ]]; then
        log_error "config: invalid choice"
        return 1
    fi
    if (( sel < 1 || sel > ${#lines[@]} )); then
        log_error "config: invalid choice"
        return 1
    fi
    printf '%s\n' "${lines[$((sel - 1))]}"
}

_config_pick_fzf() {
    local file="$1" choice rc
    [[ "${MESH_CONFIG_PICKER:-auto}" != "bash" ]] || return 1
    command -v fzf >/dev/null 2>&1 || return 1
    [[ -r /dev/tty && -w /dev/tty ]] || return 1

    choice="$(fzf \
        --prompt='mesh config> ' \
        --delimiter=$'\t' \
        --with-nth=1,2,3 \
        --height=80% \
        --reverse \
        < "$file")"
    rc=$?
    if (( rc == 0 )); then
        printf '%s\n' "$choice"
        return 0
    fi
    (( rc == 130 )) && return 130
    return 1
}

_config_choose() {
    local tmp n choice
    tmp="$(mktemp -t mesh-config-match.XXXXXX)" || return 1
    trap 'rm -f "${tmp:-}"' RETURN
    _config_filter "$TERM_ARG" > "$tmp"
    n="$(grep -c . "$tmp" 2>/dev/null || true)"
    n="${n:-0}"
    if (( n == 0 )); then
        _config_die "no config matches '${TERM_ARG:-<all>}'"
    fi
    if [[ -n "$TERM_ARG" ]] && (( n == 1 )); then
        cat "$tmp"
        return 0
    fi
    choice="$(_config_pick_fzf "$tmp")"
    case "$?" in
        0) printf '%s\n' "$choice"; return 0 ;;
        130) return 130 ;;
    esac
    choice="$(_config_pick_bash "$tmp")" || return $?
    printf '%s\n' "$choice"
}

_config_editor() {
    if [[ -n "${MESH_CONFIG_EDITOR:-}" ]]; then
        printf '%s' "$MESH_CONFIG_EDITOR"
    elif [[ -n "${VISUAL:-}" ]]; then
        printf '%s' "$VISUAL"
    elif [[ -n "${EDITOR:-}" ]]; then
        printf '%s' "$EDITOR"
    elif command -v nvim >/dev/null 2>&1; then
        printf 'nvim'
    elif command -v vim >/dev/null 2>&1; then
        printf 'vim'
    else
        printf 'vi'
    fi
}

_config_run_editor() {
    local editor="$1" path="$2" quoted
    printf -v quoted '%q' "$path"
    eval "$editor $quoted"
}

_config_diff() {
    local src="$1"
    [[ "$NO_DIFF" -eq 0 ]] || return 0
    printf '\n'
    log_info "config: git diff -- $src"
    git -C "$ID_DIR" diff -- "$src"
}

_config_install() {
    [[ "$NO_INSTALL" -eq 0 ]] || { log_info "config: deploy skipped (--no-install)"; return 0; }
    [[ -f "$INSTALL_SH" ]] || _config_die "install.sh not found at $INSTALL_SH"
    log_info "config: deploying via $INSTALL_SH"
    bash "$INSTALL_SH"
}

_config_edit_row() {
    local row="$1" label src dsts modes src_path before editor
    IFS=$'\t' read -r label src dsts modes <<<"$row"
    src_path="$ID_DIR/$src"
    [[ -f "$src_path" ]] || _config_die "source not found: $src_path"

    before="$(mktemp -t mesh-config-before.XXXXXX)" || return 1
    cp "$src_path" "$before" || { rm -f "$before"; return 1; }
    editor="$(_config_editor)"

    log_info "config: editing $label ($src)"
    _config_run_editor "$editor" "$src_path" || { rm -f "$before"; return 1; }

    if cmp -s "$before" "$src_path"; then
        rm -f "$before"
        log_info "config: no changes in $src"
        return 0
    fi
    rm -f "$before"

    _config_diff "$src" || return $?
    _config_install
}

while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            _config_usage
            exit 0
            ;;
        list|ls|--list|-l)
            LIST=1
            shift
            ;;
        --no-install)
            NO_INSTALL=1
            shift
            ;;
        --no-diff)
            NO_DIFF=1
            shift
            ;;
        --)
            shift
            [[ $# -gt 0 ]] && TERM_ARG="$1"
            shift || true
            ;;
        -*)
            _config_die "unknown flag '$1'"
            ;;
        *)
            if [[ -n "$TERM_ARG" ]]; then
                _config_die "unexpected extra term '$1'"
            fi
            TERM_ARG="$1"
            shift
            ;;
    esac
done

if (( LIST )); then
    _config_list "$TERM_ARG"
    exit 0
fi

CHOICE="$(_config_choose)" || {
    rc=$?
    (( rc == 130 )) && exit 0
    exit "$rc"
}
[[ -n "$CHOICE" ]] || exit 0
_config_edit_row "$CHOICE"
