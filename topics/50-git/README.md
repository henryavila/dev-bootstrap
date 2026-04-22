# 50-git

Applies `gitconfig.keys` to `~/.gitconfig` via `git config --global`, preserving any existing `user.*` and `credential.*`. **Since v2026-04-19** it also installs a shell fragment with short git aliases.

## What gets deployed

### 1. `git config --global` (via `install.sh`)

Applies `data/gitconfig.keys` — each line becomes `git config --global <key> <value>`. Highlights:

- `init.defaultBranch=main`, `core.pager=delta`, `merge.conflictstyle=zdiff3`
- `push.autoSetupRemote=true`, `fetch.prune=true`, `rebase.autoStash=true`
- `include.path=~/.gitconfig.local` — lets personal dotfiles override without touching the main config
- Git-level aliases: `co`, `br`, `st`, `ci`, `sw`, `lg`, `amend`, `undo`, `last`, `unstage`, `df`, `dfc`

### 2. Shell fragment (via `templates/` + `lib/deploy.sh`)

- `bashrc.d-50-git.sh` → `~/.bashrc.d/50-git.sh`
- `zshrc.d-50-git.sh` → `~/.zshrc.d/50-git.sh`

Shell aliases (short, prompt-friendly — not to be confused with the `git config alias.*` ones above):

- `g`, `gs`, `gl`, `gd`, `gds`, `gco`, `gb`, `gp`, `gaa`, `gc`, `grb`, `gsh`, `glog`, `gloga`
- `whoops` — reset hard + clean -df (destructive)
- `gmm` — merge main into current branch

Bash additionally gets `__git_complete g|gco|gb|gp|gd` so those aliases autocomplete as if they were plain `git`.

## Identity

If `user.name` / `user.email` aren't set and `GIT_NAME` / `GIT_EMAIL` were exported, they are applied. Otherwise, whatever is already in the config is preserved. In the normal flow, identity comes from the personal dotfiles via `~/.gitconfig.local`.

## GPG commit signing (opt-in)

Export `GPG_SIGN=1` (optionally with `GPG_KEY_ID=<long-id>`) before running bootstrap. The installer then:

1. Checks that `gpg` is installed.
2. If `GPG_KEY_ID` is unset, auto-picks the **first** secret key from `gpg --list-secret-keys --keyid-format=long`.
3. Sets `user.signingkey`, `commit.gpgsign=true`, `tag.gpgsign=true`. On macOS with brew, also sets `gpg.program` to the brew-installed binary (for pinentry-mac compatibility).

If no secret key exists, the installer prints the commands to generate one and leaves signing disabled — nothing silently fails.

```bash
# Generate a key once (RSA 4096, interactive):
gpg --full-generate-key

# Then enable signing on this machine:
GPG_SIGN=1 bash bootstrap.sh                           # auto-picks first key
GPG_SIGN=1 GPG_KEY_ID=ABCD1234EFGH5678 bash bootstrap.sh
```

Disable later: `git config --global --unset commit.gpgsign` + `--unset tag.gpgsign`.

## Adding/removing configs

- **Global git config:** edit `data/gitconfig.keys` and run `ONLY_TOPICS=50-git bash bootstrap.sh`.
- **Shell aliases:** edit `templates/bashrc.d-50-git.sh` (and the zsh equivalent), then rerun the bootstrap. To override locally without editing the bootstrap, use `~/.bashrc.d/99-personal-aliases.sh` in your personal dotfiles (loaded later).
