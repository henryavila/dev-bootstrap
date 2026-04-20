# ALIASES — universal (installed by dev-bootstrap)

Compact list of the aliases **every dev who ran `bootstrap.sh`** receives, regardless of personal dotfiles. Personal dotfiles can add or override; for a consolidated inventory including personal ones, see the `docs/ALIASES.md` in that dev's dotfiles repo.

## Sources in this repo

| File | Content |
|------|---------|
| `topics/20-terminal-ux/templates/bashrc.d-20-terminal-ux.sh` | listing and view aliases (ls/cat/fd…) |
| `topics/50-git/templates/bashrc.d-50-git.sh` | shell-level git aliases (g/gs/gco…) |
| `topics/50-git/data/gitconfig.keys` | git-level aliases (`git co`, `git st`) |

The first two are deployed by the bootstrap's `lib/deploy.sh` into `~/.bashrc.d/NN-<topic>.sh` (and the zshrc equivalent). The third one is applied via `git config --global alias.X Y` in the 50-git topic's `install.sh`.

## Listing / view (topic 20-terminal-ux)

| Alias | Expands to | Guard |
|-------|------------|-------|
| `ls` | `eza` | `command -v eza` |
| `ll` | `eza -l --git` | `command -v eza` |
| `la` | `eza -la --git` | `command -v eza` |
| `tree` | `eza --tree` | `command -v eza` |
| `cat` | `bat --style=plain --paging=never` | `command -v bat` |
| `bat` | `batcat` | `command -v batcat && ! bat` (Ubuntu) |
| `cat` (Ubuntu fallback) | `batcat --style=plain --paging=never` | same |
| `fd` | `fdfind` | `command -v fdfind && ! fd` (Ubuntu) |

Everything guarded by `command -v` — if the tool isn't installed, the alias isn't declared (falls back to the native command).

## Git shell-level (topic 50-git)

### Basics

| Alias | Expands to |
|-------|------------|
| `g` | `git` |
| `gs` | `git status` |
| `gl` | `git log --oneline --graph --decorate -15` |
| `gd` | `git diff` |
| `gds` | `git diff --staged` |
| `gco` | `git checkout` |
| `gb` | `git branch` |
| `gp` | `git pull` |
| `gaa` | `git add .` |
| `gc` | `git commit` |
| `grb` | `git rebase -i` |
| `gsh` | `git show` |
| `glog` | `git log --oneline --decorate --graph` |
| `gloga` | `git log --oneline --decorate --graph --all` |

### Utilities

| Alias | Expands to | Note |
|-------|------------|------|
| `whoops` | `git reset --hard && git clean -df` | ⚠️ destructive — throws away working tree + untracked |
| `gmm` | switch main + pull + back + merge main | pulls main into the current branch, keeping your place |

### Autocomplete (bash-only)

The fragment also calls `__git_complete` for `g`, `gco`, `gb`, `gp`, `gd` — Tab autocompletes branches as if you had typed `git`. Requires `bash-completion` (installed by 20-terminal-ux).

Zsh doesn't use `__git_complete` — stock `compinit` already resolves completion on aliases, and we don't want the fragility. Documented directly in `zshrc.d-50-git.sh`.

## Git git-level (topic 50-git, via global gitconfig)

Applied via `git config --global alias.X Y`. These work **inside** `git` (scripts, hooks, other commands).

| Usage | Expands to |
|-------|------------|
| `git co` | `checkout` |
| `git br` | `branch` |
| `git st` | `status` |
| `git ci` | `commit` |
| `git sw` | `switch` |
| `git last` | `log -1 HEAD` |
| `git unstage` | `reset HEAD --` |
| `git lg` | `log --oneline --graph --decorate --all` |
| `git amend` | `commit --amend --no-edit` |
| `git undo` | `reset HEAD~1 --mixed` |
| `git df` | `diff` |
| `git dfc` | `diff --cached` |

## How to add a new universal alias

1. Decide scope: listing/view → 20-terminal-ux; git → 50-git; other category → create a new topic or make the case in the PR.
2. Edit both `bashrc.d-<topic>.sh` **and** `zshrc.d-<topic>.sh` for the topic (keep parity).
3. Update this `docs/ALIASES.md` with the new row.
4. Commit with migration note + dated tag.

Dev-bootstrap versions that introduced notable alias changes:

- `v2026-04-19` — created the 50-git fragment with 16 shell-level aliases + `__git_complete`.

## Related

- `topics/20-terminal-ux/README.md` — modern CLI tools.
- `topics/50-git/README.md` — git aliases and defaults.
- Each dev's personal dotfiles — add specific aliases under `~/.bashrc.d/99-personal-aliases.sh` (they override these via the `99-` prefix).
