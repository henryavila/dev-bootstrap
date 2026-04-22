# 20-terminal-ux

Modern terminal, **fully themed out of the box** — font, color scheme, and shell plugins installed and wired so a new machine boots into the intended look immediately.

## What's installed

**CLI stack (both platforms):** `fzf bat eza zoxide ripgrep fd starship lazygit git-delta tmux neovim`
**Modern-CLI replacements:** `btop duf gping sd tealdeer dust xh procs`
**zsh plugins:** completions, autosuggestions, syntax-highlighting, history-substring-search, fzf-tab, forgit, alias-tips, zsh-abbr, you-should-use, **Powerlevel10k** (+ zinit for turbo loading)
**History engine:** atuin (manual first-run: `atuin account link`)

## Terminal emulator auto-config

Both supported emulators are pre-configured during bootstrap — users do **not** need to pick a theme or font manually.

| Platform | Emulator | Font | Color scheme | Config script |
|---|---|---|---|---|
| macOS | iTerm2 | CaskaydiaCove Nerd Font | Catppuccin (set on first theme switch) | `scripts/configure-iterm2-font.sh` (PlistBuddy surgical edit of `New Bookmarks`) |
| WSL (Windows) | Windows Terminal | CaskaydiaCove Nerd Font (user-level install via PowerShell) | **Catppuccin Mocha** (appended to `schemes[]`, set via `profiles.defaults`) | `scripts/configure-windows-terminal.sh` + `install-nerd-font.ps1` |

Both scripts are **idempotent** and **non-destructive**:
- The font installer checks the HKCU registry before downloading.
- The Windows Terminal config does a surgical `jq` merge — existing user profiles, keybindings, and custom schemes are preserved.
- A timestamped backup is written next to `settings.json` whenever a change is applied.

Native-Linux users outside WSL: no terminal emulator config runs. Use whatever terminal you prefer and point it at the fonts/themes shipped under `~/.local/share/`.

## Shell wiring

- `bashrc.d-20-terminal-ux.sh` / `zshrc.d-20-terminal-ux.sh` — initialize starship (bash only — zsh uses p10k from your personal dotfiles), zoxide, fzf keybindings, and register `ls→eza`, `cat→bat`, `fd→fdfind` (WSL).
- Fzf shortcuts: `Ctrl+R` (history), `Ctrl+T` (file finder), `Alt+C` (cd fuzzy).
- `BAT_THEME=Catppuccin-mocha` exported so `bat` renders in the same palette as the terminal.

## Customization

- **Theme change:** edit `templates/starship.toml` (bash prompt) or your personal `~/.p10k.zsh` (zsh prompt) and re-run `ONLY_TOPICS=20-terminal-ux bash bootstrap.sh`.
- **Different font:** override `NF_PS_NAME` in `configure-iterm2-font.sh` / adjust the `font.face` in `scripts/wt-settings-fragment.json`.
- **Skip terminal auto-config:** the two scripts are each gated by `-x` checks in `install.*.sh`; remove the corresponding block if you prefer to manage the emulator by hand.
