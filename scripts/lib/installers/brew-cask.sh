# Driver: brew-cask. Installs Homebrew cask.
brew_cask_check()   { brew list --cask "$1" >/dev/null 2>&1; }
brew_cask_install() { brew install --cask "$1"; }
