# Driver: npx. Always-fresh — never installed; check() always returns 1 to force the wrapper.
npx_check()   { return 1; }
npx_install() { npx -y "$1" --help >/dev/null 2>&1; }
