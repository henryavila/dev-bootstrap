# Driver: npx. Runs an npm package via npx without global install.
#
# spec format: "<package>[@version] <subcommand> [args...]"
#   e.g. "@henryavila/claudebar@latest install"
#         "@scope/tool config --flag"
#
# Detection model (2026-05-28):
#   npx leaves no on-disk footprint we can probe afterwards. Menu detection
#   is satisfied by the engine-level install marker
#   (~/.local/state/mesh/installed/<topic>__<name>.env, written by
#   install-engine.sh on successful install/verify). Drivers stay agnostic
#   of the marker; the scanner reads it directly.
#
# check():    returns 1 (always run). The engine's "skip if check passes"
#             gate does not apply to npx by design — most npx items are
#             intentionally run-every-time (atomic-skills, claudebar setup,
#             …). For items that need a "run once then skip" semantic, set
#             `check:` in items.yaml; manifest check overrides driver check.
# install():  runs `npx -y <spec>` (word-split intentional — spec carries
#             subcommand + args).
# verify():   extracts <package> from spec, runs `npx -y <package> doctor`.
#             If doctor exits non-zero or doesn't exist, trusts install.
# rollback(): extracts <package> from spec, runs `npx -y <package> uninstall`.
#             Best-effort — swallows failure if uninstall subcommand is absent.

_npx_extract_package() {
    # First token of the spec is the package (possibly @scoped with @version).
    local spec="$1"
    printf '%s' "${spec%% *}"
}

npx_check() { return 1; }

# shellcheck disable=SC2086  # intentional word-split: spec carries subcommand + args
npx_install() { npx -y $1; }

npx_verify() {
    local pkg
    pkg="$(_npx_extract_package "$1")"
    npx -y "$pkg" doctor 2>/dev/null || return 0
}

npx_rollback() {
    local pkg
    pkg="$(_npx_extract_package "$1")"
    npx -y "$pkg" uninstall 2>/dev/null || true
}

# Version-aware update (T-600): npx has no installed version to diff, so re-run
# the spec — `npx -y` fetches the latest matching the spec (a pinned @version is
# a no-op; @latest / unpinned picks up new releases). Same word-split as install.
# shellcheck disable=SC2086
npx_update() { echo "npx: re-running $1 (latest)" >&2; npx -y $1; }
