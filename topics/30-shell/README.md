# 30-shell

Cria os loaders modulares para bash e zsh, mais `~/.inputrc` compartilhado com readline.

**Install:** cria `~/.bashrc.d/`, `~/.zshrc.d/`, `~/.config/`, `~/.local/bin/`.

**Templates (deployados via `lib/deploy.sh`):**

- `bashrc` → `~/.bashrc`: enxuto, carrega `~/.bashrc.d/*.sh` em ordem alfabética e depois `~/.bashrc.local`.
- `zshrc` → `~/.zshrc`: equivalente para zsh.
- `inputrc` → `~/.inputrc`: keybindings readline compartilhados por bash, psql, gdb etc. Inclui:
  - word-wise navigation (`Ctrl+Left`/`Right` com fallbacks para terminais que emitem escape sequences diferentes)
  - word kill (`Ctrl+Backspace`, `Ctrl+Delete`)
  - Home / End
  - history prefix-search com setas Up/Down
  - defaults de completion sensatos (case-insensitive, colored stats, mark-directories, skip-completed-text, bell-style none)

**Por que um loader?** Cada topic posterior (`10-languages`, `20-terminal-ux`, `50-git`, `60-laravel-stack`) grava seu próprio fragment em `~/.bashrc.d/NN-<name>.sh` independentemente. O loader monta tudo na ordem correta quando o shell abre.

**Personalização:** customizações pessoais (identidade do shell, prompt, aliases de projeto) vão em `~/.bashrc.local` / `~/.zshrc.local` — esses arquivos nunca são versionados pelo bootstrap nem sobrescritos. Sua camada de dotfiles pessoais pode gerenciá-los.
