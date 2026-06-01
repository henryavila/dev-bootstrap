# Driver: brew-cask. Installs Homebrew cask.
# CP4 A2-F-002: `--` separator stops brew option parsing.
brew_cask_check()   { brew list --cask -- "$1" >/dev/null 2>&1; }
brew_cask_install() { brew install --cask -- "$1"; }
# Version-aware update (T-600): upgrade only when brew reports it outdated.
brew_cask_update() {
    local brew="${BREW_BIN:-brew}"
    if [[ -n "$("$brew" outdated --cask "$1" 2>/dev/null)" ]]; then
        echo "brew-cask: upgrading $1" >&2
        "$brew" upgrade --cask -- "$1"
    else
        echo "brew-cask: $1 already latest" >&2
    fi
}
