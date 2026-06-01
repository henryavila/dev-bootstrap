# Driver: deploy — render + install a bundle's template files.
#
# A `deploy`-type item carries `spec: ./templates/<subdir>` (relative to the
# topic dir; the engine cd's there before dispatch). The subdir is a
# self-contained templates root: it is processed by the standalone
# scripts/lib/deploy.sh (auto-map by filename convention, or an explicit DEPLOY
# file inside the subdir), which handles envsubst on `.template` files,
# managed-block merges, backups, CRLF stripping, refuse-overwrite of
# non-regular files, and sudo elevation for destinations outside $HOME.
#
# Per-bundle granularity (spec D-5): each bundle deploys only its own subdir,
# so deselecting a bundle means its templates are never written.
#
# Optional per-topic env hook: if `./deploy-env.sh` exists in the topic dir, it
# is sourced (with `set -a`) before deploy.sh runs, so a topic can derive the
# variables its `.template` files reference (e.g. web derives NGINX_* / CERT_DIR
# per-OS). deploy.sh only substitutes the vars in its ENVSUBST_ALLOWLIST.
#
# Deploy items are inherently idempotent (deploy.sh is a no-op when the
# rendered content already matches), so mark them `idempotent: true` in the
# manifest — the engine then skips check/verify and always runs deploy_install.

# Resolve scripts/lib/deploy.sh. The engine exports MESH_LIB_DIR (= scripts/lib)
# so we never depend on BASH_SOURCE/cwd inside the per-item subshell. Fallback to
# a source-time BASH_SOURCE capture for standalone/test sourcing.
_DEPLOY_DRIVER_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

_deploy_lib() {
    local d="${MESH_LIB_DIR:-$_DEPLOY_DRIVER_LIBDIR}"
    printf '%s/deploy.sh' "$d"
}

# Source ./deploy-env.sh (topic-dir relative) if present, exporting whatever it
# sets so deploy.sh's envsubst can see it. Best-effort: a hook failure warns but
# does not abort the deploy (the templates simply render with whatever env is
# already exported).
_deploy_source_env_hook() {
    [[ -r ./deploy-env.sh ]] || return 0
    set -a
    # shellcheck disable=SC1091
    . ./deploy-env.sh || echo "[deploy] warning: ./deploy-env.sh hook failed" >&2
    set +a
}

deploy_check() {
    # No cheap whole-subtree drift probe; deploy is idempotent, so report
    # "not yet applied" and let install run. (Engine skips this for
    # idempotent items anyway.)
    return 1
}

deploy_install() {
    local spec="$1" lib
    [[ -n "$spec" ]] || { echo "[deploy] missing spec (templates subdir)" >&2; return 64; }
    [[ -d "$spec" ]] || { echo "[deploy] not a directory: $spec" >&2; return 1; }
    lib="$(_deploy_lib)"
    [[ -r "$lib" ]] || { echo "[deploy] cannot find lib/deploy.sh at $lib" >&2; return 1; }
    _deploy_source_env_hook
    bash "$lib" "$spec"
}

deploy_verify() {
    # deploy.sh exits non-zero on any failed mapping, so a clean install()
    # is its own verification. Nothing cheap to re-probe here.
    return 0
}
