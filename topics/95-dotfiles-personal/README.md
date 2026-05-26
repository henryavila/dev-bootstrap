# 95-dotfiles-personal (opt-in)

Two activation paths — both end the same way (`$MESH_IDENTITY_REPO` cloned to `$MESH_IDENTITY_DIR`, then `bash $MESH_IDENTITY_DIR/install.sh` runs).

Related menu checkboxes can also pass optional dotfiles-layer behavior:
`MESH_NPM_GLOBAL=1` configures npm globals.

AI tools are not part of this personal-data topic. Use `82-ai-tools` for
package-level AI tool installation.

## Path A — interactive menu (recommended for first-time setup)

When `bash setup.sh` shows the menu (no `NON_INTERACTIVE=1`), opting into 95-dotfiles-personal triggers a 4-screen flow:

1. **Source choice** — "Create your dotfiles repo NOW from a GitHub template?" (Yes / No)
2. **If Yes:**
   - Template repo (default: `henryavila/dotfiles-template`; override for forks-of-forks or enterprise templates)
   - GitHub username (default: `$USER`)
   - New repo name (default: `dotfiles`)
   - Visibility: private (default, recommended) or public
3. **If No:** existing URL prompt + clone-path prompt (the legacy flow below).

Path A executes `gh repo create --template ... --clone --directory $MESH_IDENTITY_DIR` from this topic's `install.sh`. **Pre-conditions:** `gh` CLI installed (handled by 05-identity earlier in the topic order) and authenticated (`gh auth status` clean). Failures emit a `followup critical` (with the exact manual `gh repo create` invocation to retry) and `exit 1`, which marks **this topic** as failed in the bootstrap summary; subsequent topics still run, but no clone/install of your dotfiles happens. Re-run bootstrap after fixing the underlying issue (auth, scopes, name conflict).

## Path B — env-var pre-seed (CI / automation / re-runs)

Skip the menu entirely by setting variables upfront:

```bash
# Existing repo:
INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=git@github.com:youruser/dotfiles.git bash setup.sh

# Or create from template non-interactively:
CREATE_IDENTITY_FROM_TEMPLATE=1 \
INCLUDE_IDENTITY=1 \
DOTFILES_TEMPLATE_REPO=henryavila/dotfiles-template \
DOTFILES_NEW_REPO_OWNER=youruser \
DOTFILES_NEW_REPO_NAME=dotfiles \
DOTFILES_NEW_REPO_PRIVATE=1 \
NON_INTERACTIVE=1 \
bash setup.sh
```

`MESH_IDENTITY_REPO` is auto-derived from `git@github.com:$OWNER/$NAME.git` in the create-from-template path; you can override it explicitly if you want a different remote URL after creation.

## Behavior summary

1. **(Conditional)** If `CREATE_IDENTITY_FROM_TEMPLATE=1` and `$MESH_IDENTITY_DIR` is not yet a git clone, runs `gh repo create --template ... --clone --directory $MESH_IDENTITY_DIR`.
2. If `$MESH_IDENTITY_DIR/.git` exists, attempts `git pull --ff-only`. Otherwise clones `$MESH_IDENTITY_REPO`.
3. If `$MESH_IDENTITY_DIR/install.sh` exists, runs it.
4. Drift cleanup: reads `data/uninstall.list` and removes any artifacts the dotfiles fork no longer manages (apt packages, brew casks, clones, plugin caches, binaries). Idempotent. See `data/uninstall.list` for syntax.

## Why run last?

Personal configs (SSH, git identity, overrides in `~/.bashrc.local`) layer on top of the stack installed by earlier topics. The dotfiles-template produces the right skeleton for that.
