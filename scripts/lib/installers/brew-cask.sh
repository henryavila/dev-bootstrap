# Driver: brew-cask. Installs Homebrew cask.
# CP4 A2-F-002: `--` separator stops brew option parsing.
# Read probes use ${BREW_BIN:-brew} + offline guards (same rationale as
# brew-formula: a plain `brew list` can hit the API and fail when DNS is down).
brew_cask_check()   {
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
        "${BREW_BIN:-brew}" list --cask -- "$1" >/dev/null 2>&1
}
brew_cask_install() { "${BREW_BIN:-brew}" install --cask -- "$1"; }
# repair() (engine --repair sweep): force a reinstall of an installed-but-broken
# cask. `brew install --cask` no-ops when present, so repair needs reinstall.
brew_cask_repair() {
    local brew="${BREW_BIN:-brew}"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    echo "brew-cask: reinstalling $1 (repair)" >&2
    "$brew" reinstall --cask -- "$1"
}
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
