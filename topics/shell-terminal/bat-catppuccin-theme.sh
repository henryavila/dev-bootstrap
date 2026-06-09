#!/usr/bin/env bash
BAT_THEMES_DIR="$HOME/.config/bat/themes"
BAT_THEME_FILE="$BAT_THEMES_DIR/Catppuccin Mocha.tmTheme"
check()    {
    command -v bat >/dev/null 2>&1 || return 0   # bat not installed; nothing to do
    [[ -f "$BAT_THEME_FILE" ]]
}
install()  {
    command -v bat >/dev/null 2>&1 || return 0
    mkdir -p "$BAT_THEMES_DIR"
    curl -fsSL -o "$BAT_THEME_FILE" \
        "https://github.com/catppuccin/bat/raw/main/themes/Catppuccin%20Mocha.tmTheme"
    bat cache --build >/dev/null 2>&1 || true
}
verify()   { check; }
rollback() { [[ -f "$BAT_THEME_FILE" ]] && rm -f "$BAT_THEME_FILE"; }
