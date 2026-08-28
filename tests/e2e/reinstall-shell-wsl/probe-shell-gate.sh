#!/usr/bin/env bash
# RED/GREEN probes for the mesh reinstall shell WSL gate.
# Usage: MODE=red|green bash probe-shell-gate.sh
set -u
MODE="${MODE:-red}"
FAIL=0
pass() { printf '  PASS %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

passwd_shell="$(getent passwd "$USER" | cut -d: -f7)"
echo "mode=$MODE user=$USER passwd_shell=$passwd_shell HOME=$HOME"

zsh_bin="$(command -v zsh 2>/dev/null || true)"
if [[ "$passwd_shell" != /usr/bin/zsh && "$passwd_shell" != "$zsh_bin" ]]; then
    fail "login shell is not zsh (got $passwd_shell)"
else
    pass "login shell is zsh ($passwd_shell)"
fi

has_marker=0
if [[ -f "$HOME/.zshrc" ]] && grep -qiE 'managed by (mesh-workstation|dev-bootstrap)' "$HOME/.zshrc"; then
    has_marker=1
fi
loads_d=0
if [[ -f "$HOME/.zshrc" ]] && grep -q 'zshrc.d' "$HOME/.zshrc"; then
    loads_d=1
fi
has_prompt=0
[[ -f "$HOME/.zshrc.d/90-prompt.sh" ]] && has_prompt=1

zsh_p10k="$(zsh -lic 'whence -w p10k 2>/dev/null || true' 2>/dev/null || true)"
zsh_fzf="$(zsh -lic 'bindkey -L 2>/dev/null | grep -i fzf || true' 2>/dev/null || true)"

echo "zshrc exists=$([[ -f $HOME/.zshrc ]] && echo yes || echo no) marker=$has_marker loads_d=$loads_d prompt_frag=$has_prompt"
echo "zsh p10k: ${zsh_p10k:-<none>}"
echo "zsh fzf bindkey: ${zsh_fzf:-<none>}"

if [[ "$MODE" == red ]]; then
    if [[ "$has_marker" -eq 1 ]]; then
        fail "RED: ~/.zshrc already mesh-managed"
    else
        pass "RED: ~/.zshrc is not mesh-managed"
    fi
    if [[ "$loads_d" -eq 1 ]]; then
        fail "RED: ~/.zshrc already loads zshrc.d"
    else
        pass "RED: ~/.zshrc does not load zshrc.d"
    fi
    if [[ "$has_prompt" -eq 1 ]]; then
        fail "RED: 90-prompt.sh already present"
    else
        pass "RED: no 90-prompt.sh"
    fi
    if [[ "$zsh_p10k" == *function* || "$zsh_p10k" == *alias* || "$zsh_p10k" == *command* ]]; then
        fail "RED: p10k already available in login zsh"
    else
        pass "RED: p10k not available in login zsh"
    fi
    if [[ -n "$zsh_fzf" ]]; then
        fail "RED: fzf keybindings already in zsh"
    else
        pass "RED: fzf keybindings absent in zsh (pre-fix: only bash-completion)"
    fi
else
    if [[ "$has_marker" -eq 1 ]]; then
        pass "GREEN: ~/.zshrc is mesh-managed"
    else
        fail "GREEN: ~/.zshrc missing mesh marker"
    fi
    if [[ "$loads_d" -eq 1 ]]; then
        pass "GREEN: ~/.zshrc loads zshrc.d"
    else
        fail "GREEN: ~/.zshrc does not load zshrc.d"
    fi
    if [[ "$has_prompt" -eq 1 ]]; then
        pass "GREEN: 90-prompt.sh deployed"
    else
        fail "GREEN: 90-prompt.sh missing"
    fi
    if [[ "$zsh_p10k" == *function* || "$zsh_p10k" == *alias* || "$zsh_p10k" == *command* ]]; then
        pass "GREEN: p10k available in login zsh ($zsh_p10k)"
    else
        fail "GREEN: p10k not available in login zsh (${zsh_p10k:-empty})"
    fi
    if [[ -n "$zsh_fzf" ]]; then
        pass "GREEN: fzf keybindings present in zsh"
    else
        fail "GREEN: fzf keybindings still missing in zsh"
    fi
    if command -v php >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1 || command -v nginx >/dev/null 2>&1; then
        fail "GREEN: php/mysql/nginx present — reinstall must not touch services"
    else
        pass "GREEN: php/mysql/nginx absent"
    fi
    if [[ -f "$HOME/.config/mesh/selections.list" ]]; then
        fail "GREEN: selections.list was created/persisted (must stay absent on a virgin box)"
    else
        pass "GREEN: selections.list was not persisted"
    fi
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "GATE $MODE PASS"
    exit 0
fi
echo "GATE $MODE FAIL ($FAIL checks)"
exit 1
