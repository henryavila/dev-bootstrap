# Driver: npm-global. Installs npm package globally.
npm_global_check()   { npm list -g --depth=0 "$1" 2>/dev/null | grep -q "$1@"; }
npm_global_install() { npm install -g "$1"; }
