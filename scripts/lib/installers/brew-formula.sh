# Driver: brew-formula. Installs Homebrew formula.
brew_formula_check()   { brew list --formula "$1" >/dev/null 2>&1; }
brew_formula_install() { brew install --formula "$1"; }
