# Driver: brew-cask. Installs Homebrew cask.
# CP4 A2-F-002: `--` separator stops brew option parsing.
brew_cask_check()   { brew list --cask -- "$1" >/dev/null 2>&1; }
brew_cask_install() { brew install --cask -- "$1"; }
