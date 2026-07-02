#!/usr/bin/env bash
ZINIT_DIR="$HOME/.local/share/zinit"
check()    { [[ -f "$ZINIT_DIR/zinit.git/zinit.zsh" ]]; }
install()  {
    mkdir -p "$ZINIT_DIR"
    # The installer's edit_zshrc() ALWAYS appends zinit's bootstrap block to
    # $ZSHRC (default ~/.zshrc), CREATING the file — `yes n` only declines the
    # optional *annexes*, not that core edit (the old "pipe n leaves ~/.zshrc
    # alone" assumption was wrong). mesh owns ~/.zshrc (deployed WITH its
    # "managed by mesh-workstation" marker by shell-fragments, and loads zinit
    # from ~/.zshrc.local by design), so an unmarked ~/.zshrc left here makes the
    # deploy overwrite-guard refuse it and ABORTS the whole bootstrap. The
    # installer honours a ZSHRC override (install.sh: ZSHRC="${ZSHRC:-…/.zshrc}"),
    # so point it at a throwaway: zinit still clones to ~/.local/share/zinit, but
    # its rc edit goes nowhere. `yes n` still auto-answers the annex prompt so the
    # non-interactive run cannot block on stdin.
    local _throwaway; _throwaway="$(mktemp)"
    yes n | ZSHRC="$_throwaway" bash -c "$(curl --fail --show-error --silent --location \
        https://raw.githubusercontent.com/zdharma-continuum/zinit/HEAD/scripts/install.sh)" \
        >/dev/null 2>&1 || true
    rm -f "$_throwaway"
    check || { echo "[zinit] install state check failed — shell will degrade gracefully" >&2; return 1; }
}
verify()   { check; }
repair() { install; }

rollback() { local dir="$ZINIT_DIR"; [[ -d "$dir" ]] && rm -rf "$dir"; }
