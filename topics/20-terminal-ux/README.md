# 20-terminal-ux

Terminal moderno pronto out-of-the-box.

**Ferramentas:** `fzf bat eza zoxide ripgrep fd starship lazygit git-delta`

**Fonte:** CaskaydiaCove Nerd Font (Mac via brew cask; Windows via `windows/install-wsl.ps1`).

**Config:**
- `starship.toml` com **Catppuccin Mocha** embutido (tema dark; ícones Nerd Font).
- `bashrc.d-20-terminal-ux.sh` / `zshrc.d-20-terminal-ux.sh` — inicializam starship, zoxide e fzf; criam aliases `ls→eza`, `cat→bat`, `fd→fdfind` (WSL).

**Fzf keybindings:** `Ctrl+R` (history), `Ctrl+T` (file finder), `Alt+C` (jump dir).

**Customização:** trocar tema — editar `templates/starship.toml` e re-executar `bash bootstrap.sh ONLY_TOPICS=20-terminal-ux`.
