#!/usr/bin/env bash
# tests/integration/php-install-no-recommends.test.sh
#
# Regression: bug found 2026-04-24 on crc.
#
# `apt-get install php8.4` (without --no-install-recommends) drags apache2
# in via the chain:
#   php8.4 → Recommends: libapache2-mod-php8.4 | php8.4-fpm
#   libapache2-mod-php8.4 → Depends: apache2, apache2-bin, ...
#
# When `phpX.Y-fpm` is also in the explicit install list AND none of the
# alternatives are pre-installed, apt PICKS THE FIRST OPTION
# (libapache2-mod-php) — not the one we'd prefer. Result on crc:
# apache2 quietly installed, started, owned :80, blocked nginx for 22h.
# The first-match-wins behaviour is documented in apt(8) but not enforced
# at install-list parse time, so the pkgs=("phpX.Y-fpm" ...) array is not
# enough on its own to defeat it.
#
# The contract this test enforces: any apt-get install line whose package
# list contains a `phpX.Y` meta-package or a `libapache2-mod-phpX.Y` shim
# MUST also pass `--no-install-recommends`. We list everything we need in
# pkgs[] explicitly — recommends only ADD packages we did not request.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

# Files that install PHP packages on Linux.
TARGETS=(
    "$ROOT/topics/10-languages/install.wsl.sh"
    "$ROOT/topics/60-web-stack/install.wsl.sh"
    "$ROOT/topics/60-web-stack/scripts/install-mssql-driver.sh"
)

echo
echo "═══ apt-get install for PHP must use --no-install-recommends ═══"

for f in "${TARGETS[@]}"; do
    if [[ ! -f "$f" ]]; then
        fail "missing target: $f"
        continue
    fi
    rel="${f#"$ROOT"/}"

    # Each apt-get install line that mentions a php-related variable, array,
    # or literal MUST also have --no-install-recommends on the same line.
    # Scan the file linewise; for every install line touching PHP, assert.
    while IFS= read -r line; do
        # Skip comment-only lines
        case "$line" in
            \#*|*[[:space:]]\#*) ;;  # has a comment — still parse
        esac
        # Quick filter: must be an actual apt-get command, not an `info`/`echo`
        # string that happens to contain the literal "apt install". Require
        # `sudo apt-get` (real form used in this repo).
        if ! grep -qE '^[[:space:]]*sudo([[:space:]][A-Z_]+=[^[:space:]]+)*[[:space:]]+apt-get[[:space:]]+install\b' <<< "$line"; then
            continue
        fi
        # Skip pure comments
        case "$line" in
            \#*) continue ;;
            [[:space:]]\#*) continue ;;
        esac
        # Must touch a PHP-installing array/var/literal:
        #   - "${missing[@]}" (10-languages, 60-web-stack)
        #   - "${missing_deps[@]}" (php-dev resolution)
        #   - "php${ver}-..." literal
        case "$line" in
            *missing*|*"php\${ver}"*|*"php\$ver"*|*php8.*)
                # OK, this line installs PHP — must have --no-install-recommends
                if [[ "$line" == *"--no-install-recommends"* ]]; then
                    pass "$rel: PHP install line has --no-install-recommends"
                else
                    fail "$rel: apt-get install line installs PHP packages without --no-install-recommends — apache2 will be dragged in via libapache2-mod-php Recommends"
                    printf "      offending line: %s\n" "$line" | sed 's/^/        /' >&2
                fi
                ;;
        esac
    done < "$f"
done

# Also assert that the comment justifying --no-install-recommends is
# present somewhere in 10-languages/install.wsl.sh — this is the kind of
# subtle apt behaviour future maintainers will want to remove "since the
# pkgs array is explicit anyway". The comment must explain WHY.
if grep -qE '(no-install-recommends|libapache2-mod-php)' "$ROOT/topics/10-languages/install.wsl.sh"; then
    pass "10-languages/install.wsl.sh: justifies --no-install-recommends in a comment"
else
    fail "10-languages/install.wsl.sh: --no-install-recommends needs a comment naming libapache2-mod-php so future maintainers don't 'clean it up'"
fi

summary
