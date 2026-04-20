# 20-terminal-ux

Modern terminal, ready out-of-the-box.

**Tools:** `fzf bat eza zoxide ripgrep fd starship lazygit git-delta`

**Font:** CaskaydiaCove Nerd Font (Mac via brew cask; Windows via `windows/install-wsl.ps1`).

**Config:**
- `starship.toml` with **Catppuccin Mocha** baked in (dark theme, Nerd Font glyphs).
- `bashrc.d-20-terminal-ux.sh` / `zshrc.d-20-terminal-ux.sh` — initialize starship, zoxide, and fzf; create aliases `ls→eza`, `cat→bat`, `fd→fdfind` (WSL).

**Fzf keybindings:** `Ctrl+R` (history), `Ctrl+T` (file finder), `Alt+C` (jump dir).

**Customization:** to change the theme, edit `templates/starship.toml` and re-run `ONLY_TOPICS=20-terminal-ux bash bootstrap.sh`.
