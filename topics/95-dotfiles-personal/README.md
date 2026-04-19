# 95-dotfiles-personal (opt-in via env var)

Ativado quando `DOTFILES_REPO` está setado:

```bash
DOTFILES_REPO=git@github.com:henryavila/dotfiles.git bash bootstrap.sh
```

**Comportamento:**
1. Clona `$DOTFILES_REPO` em `$DOTFILES_DIR` (default `~/dotfiles`). Se já existe, tenta `git pull --ff-only`.
2. Se `$DOTFILES_DIR/install.sh` existe, executa.

**Por que ficar por último?** As configs pessoais (SSH, git identity, overrides em `~/.bashrc.local`) aplicam sobre o stack instalado pelos topics anteriores. O dotfiles-template gera o skeleton certo para isso.
