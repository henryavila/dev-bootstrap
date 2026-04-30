# 95-dotfiles-personal (opt-in)

Two activation paths — both end the same way (`$DOTFILES_REPO` cloned to `$DOTFILES_DIR`, then `bash $DOTFILES_DIR/install.sh` runs).

## Path A — interactive menu (recommended for first-time setup)

When `bash bootstrap.sh` shows the menu (no `NON_INTERACTIVE=1`), opting into 95-dotfiles-personal triggers a 4-screen flow:

1. **Source choice** — "Create your dotfiles repo NOW from a GitHub template?" (Yes / No)
2. **If Yes:**
   - Template repo (default: `henryavila/dotfiles-template`; override for forks-of-forks or enterprise templates)
   - GitHub username (default: `$USER`)
   - New repo name (default: `dotfiles`)
   - Visibility: private (default, recommended) or public
3. **If No:** existing URL prompt + clone-path prompt (the legacy flow below).

Path A executes `gh repo create --template ... --clone --directory $DOTFILES_DIR` from this topic's `install.sh`. **Pre-conditions:** `gh` CLI installed (handled by 05-identity earlier in the topic order) and authenticated (`gh auth status` clean). Failures emit a `followup critical` with a manual `gh repo create` invocation — bootstrap continues without blocking.

## Path B — env-var pre-seed (CI / automation / re-runs)

Skip the menu entirely by setting variables upfront:

```bash
# Existing repo:
DOTFILES_REPO=git@github.com:youruser/dotfiles.git bash bootstrap.sh

# Or create from template non-interactively:
CREATE_DOTFILES_FROM_TEMPLATE=1 \
DOTFILES_TEMPLATE_REPO=henryavila/dotfiles-template \
DOTFILES_NEW_REPO_OWNER=youruser \
DOTFILES_NEW_REPO_NAME=dotfiles \
DOTFILES_NEW_REPO_PRIVATE=1 \
NON_INTERACTIVE=1 \
bash bootstrap.sh
```

`DOTFILES_REPO` is auto-derived from `git@github.com:$OWNER/$NAME.git` in the create-from-template path; you can override it explicitly if you want a different remote URL after creation.

## Behavior summary

1. **(Conditional)** If `CREATE_DOTFILES_FROM_TEMPLATE=1` and `$DOTFILES_DIR` is not yet a git clone, runs `gh repo create --template ... --clone --directory $DOTFILES_DIR`.
2. If `$DOTFILES_DIR/.git` exists, attempts `git pull --ff-only`. Otherwise clones `$DOTFILES_REPO`.
3. If `$DOTFILES_DIR/install.sh` exists, runs it.

## Why run last?

Personal configs (SSH, git identity, overrides in `~/.bashrc.local`) layer on top of the stack installed by earlier topics. The dotfiles-template produces the right skeleton for that.
