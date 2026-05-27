# Driver: npx. Runs an npm package via npx without global install.
#
# spec format: "<package>[@version] <subcommand> [args...]"
#   e.g. "@henryavila/claudebar@latest install"
#         "@scope/tool config --flag"
#
# check():    returns 1 (always run). Use manifest `check:` in items.yaml
#             for items that need idempotent skip (engine evaluates check:
#             BEFORE the driver's _check, so it acts as an override).
# install():  runs `npx -y <spec>` (word-split intentional — spec carries
#             subcommand + args).
# verify():   extracts <package> from spec, runs `npx -y <package> doctor`.
#             If doctor exits non-zero or doesn't exist, falls back to
#             exit code 0 (trust install). Manifest `check:` also serves
#             as verify fallback per engine contract.
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
