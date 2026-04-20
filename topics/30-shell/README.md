# 30-shell

Creates the modular loaders for bash and zsh, plus a shared `~/.inputrc` for readline.

**Install:** creates `~/.bashrc.d/`, `~/.zshrc.d/`, `~/.config/`, `~/.local/bin/`.

**Templates (deployed via `lib/deploy.sh`):**

- `bashrc` → `~/.bashrc`: lean, loads `~/.bashrc.d/*.sh` alphabetically and then `~/.bashrc.local`.
- `zshrc` → `~/.zshrc`: equivalent for zsh.
- `inputrc` → `~/.inputrc`: readline keybindings shared by bash, psql, gdb, etc. Includes:
  - word-wise navigation (`Ctrl+Left`/`Right` with fallbacks for terminals emitting different escape sequences)
  - word kill (`Ctrl+Backspace`, `Ctrl+Delete`)
  - Home / End
  - history prefix-search with Up/Down
  - sensible completion defaults (case-insensitive, colored stats, mark-directories, skip-completed-text, bell-style none)

**Why a loader?** Every later topic (`10-languages`, `20-terminal-ux`, `50-git`, `60-laravel-stack`) writes its own fragment under `~/.bashrc.d/NN-<name>.sh` independently. The loader wires everything in the right order when the shell opens.

**Personalization:** personal customizations (shell identity, prompt, project-specific aliases) live in `~/.bashrc.local` / `~/.zshrc.local` — these files are never versioned by the bootstrap nor overwritten. Your personal dotfiles layer manages them.
