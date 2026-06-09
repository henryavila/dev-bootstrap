# personal (required)

Clones your private **mesh-identity** repo and applies it — the layer that makes
the machine *yours* (SSH config, git identity, shell overrides, personal aliases,
secrets deploy, etc.). Runs last, on top of the stack the earlier topics install.

Activated by `MESH_IDENTITY_REPO` (the menu collects it, or pre-seed it for
automation):

```bash
INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=git@github.com:youruser/mesh-identity.git bash setup.sh
```

Optional: `MESH_NPM_GLOBAL=1` to also configure npm globals. AI tooling is a
separate topic (`ai`), not part of this personal layer.

## Behavior (`apply.sh`)

1. `identity_ensure_repo`: if `$MESH_IDENTITY_DIR/.git` exists, `git pull --ff-only`;
   otherwise clone `$MESH_IDENTITY_REPO` into `$MESH_IDENTITY_DIR`
   (default `~/mesh-identity`).
2. If `$MESH_IDENTITY_DIR/install.sh` exists, run it (the identity repo's own thin
   deploy script — see its `deploy.map`).
3. Drift cleanup: read `data/uninstall.list` and remove artifacts the identity fork
   used to install but no longer ships (apt packages, brew casks, clones, plugin
   caches, binaries). Idempotent — see `data/uninstall.list` for syntax.

Marked `idempotent: true`: re-applied on every run; the fork's own `install.sh`
handles "already applied" fast paths. `verify` only checks the repo dir exists;
`rollback` is a no-op (never auto-removes your applied identity).
