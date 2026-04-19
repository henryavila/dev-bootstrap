# 30-shell

Cria os loaders modulares para bash e zsh.

**Install:** cria `~/.bashrc.d/`, `~/.zshrc.d/`, `~/.config/`, `~/.local/bin/`.

**Templates:**
- `bashrc` — `~/.bashrc` enxuto que carrega `~/.bashrc.d/*.sh` (ordem alfabética) e depois `~/.bashrc.local`.
- `zshrc` — equivalente para zsh.
- `inputrc` — keybindings readline (word-wise navigation, history prefix search).

**Por que um loader?** Cada topic posterior (`10-languages`, `20-terminal-ux`, `60-laravel-stack`) grava seu próprio fragment em `~/.bashrc.d/NN-<name>.sh` independentemente. O loader monta tudo na ordem correta quando o shell abre.

**Personalização:** customizações pessoais (identidade do shell, prompt, aliases de projeto) vão em `~/.bashrc.local` / `~/.zshrc.local` — esses arquivos nunca são versionados nem sobrescritos.
