# Driver: brew-formula. Installs Homebrew formula.
# CP4 A2-F-002: `--` separator stops brew option parsing.
brew_formula_check()   { brew list --formula -- "$1" >/dev/null 2>&1; }
brew_formula_install() { brew install --formula -- "$1"; }
