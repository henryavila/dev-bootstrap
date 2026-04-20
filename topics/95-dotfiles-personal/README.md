# 95-dotfiles-personal (opt-in via env var)

Enabled when `DOTFILES_REPO` is set:

```bash
DOTFILES_REPO=git@github.com:henryavila/dotfiles.git bash bootstrap.sh
```

**Behavior:**
1. Clones `$DOTFILES_REPO` into `$DOTFILES_DIR` (default `~/dotfiles`). If already present, attempts `git pull --ff-only`.
2. If `$DOTFILES_DIR/install.sh` exists, runs it.

**Why run last?** Personal configs (SSH, git identity, overrides in `~/.bashrc.local`) layer on top of the stack installed by earlier topics. The dotfiles-template produces the right skeleton for that.
