# Driver: brew-formula. Installs Homebrew formula.
# CP4 A2-F-002: `--` separator stops brew option parsing.
brew_formula_check()   { brew list --formula -- "$1" >/dev/null 2>&1; }
brew_formula_install() { brew install --formula -- "$1"; }
# Version-aware update (T-600): upgrade only when brew reports it outdated.
brew_formula_update() {
    local brew="${BREW_BIN:-brew}"
    if [[ -n "$("$brew" outdated --formula "$1" 2>/dev/null)" ]]; then
        echo "brew-formula: upgrading $1" >&2
        "$brew" upgrade --formula -- "$1"
    else
        echo "brew-formula: $1 already latest" >&2
    fi
}
