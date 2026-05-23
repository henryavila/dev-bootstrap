# Driver: npm-global. Installs npm package globally.
# check uses --parseable + non-empty output (regex metachars in scoped pkg
# names like `@foo/bar.baz` would false-match with the previous grep "$1@").
npm_global_check()   {
    local out
    out=$(npm list -g --depth=0 --parseable "$1" 2>/dev/null) || return 1
    [[ -n "$out" ]]
}
npm_global_install() { npm install -g "$1"; }
