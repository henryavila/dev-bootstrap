# Driver: npx. Always-fresh — never installed; check() always returns 1 to
# force the run every time. verify() trusts the install exit code (npx
# packages are fire-and-forget — no persistent binary to probe).
npx_check()   { return 1; }
npx_install() { npx -y "$1" --help >/dev/null 2>&1; }
npx_verify()  { return 0; }
