# Driver: npm-global. Installs npm package globally.
# check uses --parseable + non-empty output (regex metachars in scoped pkg
# names like `@foo/bar.baz` would false-match with the previous grep "$1@").
npm_global_check()   {
    local out
    out=$(npm list -g --depth=0 --parseable "$1" 2>/dev/null) || return 1
    [[ -n "$out" ]]
}
npm_global_install() { npm install -g "$1"; }
# Version-aware update (T-600): `npm outdated -g <pkg>` exits 0 when the package
# is current, non-zero when a newer version exists — only reinstall if stale.
npm_global_update() {
    if npm outdated -g "$1" >/dev/null 2>&1; then
        echo "npm-global: $1 already latest" >&2
    else
        echo "npm-global: updating $1" >&2
        npm install -g "$1"
    fi
}
