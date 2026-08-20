#!/usr/bin/env bash
# tests/integration/php-pear-pecl-dep.test.sh
#
# Regression: PECL baseline install on WSL requires /usr/bin/pecl from the
# php-pear package. languages/wsl/php-stack.sh installs php${ver}-dev and
# extension build deps under --no-install-recommends, but historically never
# installed php-pear itself. pecl-install.sh then skipped every extension
# ("required binary /usr/bin/pecl missing"), verify() failed the PECL baseline,
# and the engine aborted — operators had to `apt install php-pear` by hand.
#
# Contract: the WSL PHP stack MUST explicitly install php-pear (which provides
# /usr/bin/pecl) among the PECL toolchain packages before calling
# pecl_install_for_version_linux.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

WSL_STACK="$ROOT/topics/languages/wsl/php-stack.sh"
PECL_LIB="$ROOT/scripts/lib/pecl-install.sh"

echo
echo "═══ WSL PHP stack must install php-pear before PECL builds ═══"

assert_file_exists "$WSL_STACK" "languages/wsl/php-stack.sh exists"
assert_file_exists "$PECL_LIB" "scripts/lib/pecl-install.sh exists"

# Explicit package name in the PECL toolchain / build-deps list (not only a comment).
# Accept either:
#   core_build_deps=(... php-pear ...)
#   or a dedicated apt-get install that names php-pear near the PECL section.
if grep -nE 'php-pear' "$WSL_STACK" | grep -vE '^[[:space:]]*#' >/dev/null; then
    pass "wsl/php-stack.sh names php-pear as an installable package (not only a comment)"
else
    fail "wsl/php-stack.sh must apt-install php-pear so /usr/bin/pecl exists before pecl_install_for_version_linux"
fi

# php-pear must appear in the same dependency-gathering region that feeds the
# PECL build apt-get (core_build_deps / combined_deps / missing_deps), not in
# an unrelated comment or string elsewhere in the file.
pecl_dep_region="$(awk '
    /PECL extensions|core_build_deps|pecl_build_deps|combined_deps|missing_deps|php\$\{ver\}-dev|pecl_install_for_version_linux/ {in_region=1}
    in_region {print}
    /pecl_install_for_version_linux/ && seen_call++ {exit}
' "$WSL_STACK")"

if grep -qE '\bphp-pear\b' <<< "$pecl_dep_region"; then
    pass "php-pear is listed in the PECL toolchain/deps region of wsl/php-stack.sh"
else
    fail "php-pear must be part of the PECL build-deps / core toolchain list (near core_build_deps), not a stray mention"
fi

# Fail closed after toolchain apt if pecl is still missing — do not rely on
# pecl-install.sh's per-ext skip (that masks the gap until verify aborts).
if grep -qE '/usr/bin/pecl' "$WSL_STACK" \
    && grep -qE '_phpstack_fail=1' "$WSL_STACK"; then
    pass "wsl/php-stack.sh fail-closes when /usr/bin/pecl is still missing after deps"
else
    fail "wsl/php-stack.sh must set _phpstack_fail when /usr/bin/pecl is missing after php-pear install"
fi

# pecl-install still documents /usr/bin/pecl as required — keep the shared lib
# and the stack install in agreement.
assert_pattern_present "$PECL_LIB" '/usr/bin/pecl|pecl_bin' \
    "pecl-install.sh still resolves a pecl binary path"

summary
