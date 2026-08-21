#!/usr/bin/env bash
# Shell-terminal item order + soft_fail: a failed CDN/git clone must not leave
# the user in zsh without mesh zshrc/fzf fragments, and must not abort fonts/WT.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

MF="$WS/topics/shell-terminal/manifest.yaml"
PARSER="$WS/scripts/lib/yaml-parse.sh"
assert_file_exists "$MF" "shell-terminal manifest exists"
assert_file_exists "$PARSER" "yaml-parse.sh exists"

parsed="$(bash "$PARSER" < "$MF")" || {
    fail "yaml-parse.sh failed on shell-terminal/manifest.yaml"
    summary
    exit 1
}

# shellcheck disable=SC1090
eval "$parsed"
assert_eq "${__YAML_PARSE_OK:-0}" "1" "manifest parse ok"

bundle_index_by_name() {
    local want="$1" i name_v
    local n="${BUNDLE_COUNT:-0}"
    for ((i=0; i<n; i++)); do
        name_v="BUNDLE_${i}_NAME"
        if [[ "${!name_v:-}" == "$want" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

item_index_by_name() {
    local b="$1" want="$2" i name_v
    local n_var="BUNDLE_${b}_ITEM_COUNT"
    local n="${!n_var:-0}"
    for ((i=0; i<n; i++)); do
        name_v="BUNDLE_${b}_ITEM_${i}_NAME"
        if [[ "${!name_v:-}" == "$want" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

item_soft_fail() {
    local b="$1" i="$2"
    local v="BUNDLE_${b}_ITEM_${i}_SOFT_FAIL"
    printf '%s' "${!v:-0}"
}

cli="$(bundle_index_by_name cli-tools)" || { fail "cli-tools bundle missing"; cli=""; }
zsh="$(bundle_index_by_name zsh)" || { fail "zsh bundle missing"; zsh=""; }

if [[ -n "$cli" ]]; then
    frag="$(item_index_by_name "$cli" shell-fragments)" || { fail "cli-tools/shell-fragments missing"; frag=99; }
    atuin="$(item_index_by_name "$cli" atuin-wsl)" || { fail "cli-tools/atuin-wsl missing"; atuin=0; }
    rust="$(item_index_by_name "$cli" rust-bins-wsl)" || rust=""
    if [[ "$frag" -lt "$atuin" ]]; then
        pass "cli-tools deploys shell-fragments before atuin-wsl"
    else
        fail "cli-tools must deploy shell-fragments before atuin-wsl (fragments=$frag atuin=$atuin) so a failed download still wires fzf for bash AND zsh"
    fi
    if [[ -n "$rust" ]]; then
        if [[ "$frag" -lt "$rust" ]]; then
            pass "cli-tools deploys shell-fragments before rust-bins-wsl"
        else
            fail "cli-tools must deploy shell-fragments before rust-bins-wsl (fragments=$frag rust=$rust)"
        fi
    fi
    atuin_sf="$(item_soft_fail "$cli" "$atuin")"
    assert_eq "$atuin_sf" "1" "atuin-wsl is soft_fail so a hung setup.atuin.sh cannot abort zsh/fonts"
fi

if [[ -n "$zsh" ]]; then
    zsh_pkg="$(item_index_by_name "$zsh" zsh-wsl)" || { fail "zsh bundle is missing an explicit zsh-wsl apt item"; zsh_pkg=99; }
    autosug="$(item_index_by_name "$zsh" zsh-autosuggestions-wsl)" || autosug=""
    zinit="$(item_index_by_name "$zsh" zinit)" || { fail "zinit item missing"; zinit=0; }
    fzf_tab="$(item_index_by_name "$zsh" fzf-tab)" || { fail "fzf-tab item missing"; fzf_tab=0; }
    p10k="$(item_index_by_name "$zsh" powerlevel10k)" || { fail "powerlevel10k item missing"; p10k=0; }
    zsh_frag="$(item_index_by_name "$zsh" shell-fragments)" || { fail "zsh/shell-fragments missing"; zsh_frag=0; }
    chsh="$(item_index_by_name "$zsh" zsh-default-shell)" || { fail "zsh-default-shell missing"; chsh=0; }

    if [[ "$zsh_pkg" != "99" && -n "$autosug" && "$zsh_pkg" -lt "$autosug" ]]; then
        pass "explicit zsh-wsl apt item is installed before zsh plugins"
    elif [[ "$zsh_pkg" != "99" ]]; then
        pass "explicit zsh-wsl apt item is present"
    fi

    if [[ "$zsh_frag" -lt "$chsh" ]]; then
        pass "zsh deploys ~/.zshrc (shell-fragments) before chsh (zsh-default-shell)"
    else
        fail "zsh must deploy shell-fragments before zsh-default-shell (fragments=$zsh_frag chsh=$chsh) so Windows Terminal/login zsh sources fzf keybindings"
    fi

    assert_eq "$(item_soft_fail "$zsh" "$zinit")" "1" "zinit is soft_fail (network install must not abort chsh/fonts)"
    assert_eq "$(item_soft_fail "$zsh" "$fzf_tab")" "1" "fzf-tab is soft_fail (git clone must not abort remaining items)"
    assert_eq "$(item_soft_fail "$zsh" "$p10k")" "1" "powerlevel10k is soft_fail (git clone must not abort remaining items)"
fi

summary
