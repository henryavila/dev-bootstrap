#!/usr/bin/env bash
# tests/integration/pecl-version-pinning.test.sh
#
# Behavioral regression for the WSL PECL "wrong ABI" bug class.
#
# Static grep tests (in regression-recent-fixes.test.sh) confirm our
# installer sets PHP_PEAR_PHP_BIN + PHP_PEAR_BIN_DIR + PHP_PEAR_EXTENSION_DIR
# and creates symlinks in a scratch dir. Those catch a contributor who
# deletes the env vars. They DO NOT catch a contributor who changes the
# env var names to something PEAR ignores (the earlier version of the
# fix used PHP_PEAR_PHPIZE_BIN — which PEAR does not honor at all —
# and still passed the static "env var is set" tests).
#
# This file verifies the CONTRACT that the fix depends on:
#
#   1. /usr/bin/pecl really is a shell script that honors PHP_PEAR_PHP_BIN.
#   2. PEAR's Config.php really reads PHP_PEAR_BIN_DIR + EXTENSION_DIR
#      from the environment.
#   3. PEAR's Builder.php really calls `phpize` + `php-config` via PATH
#      lookup (not absolute path) — which is what makes the scratch-dir
#      symlink trick work.
#   4. A scratch dir with `phpize → phpize8.3` prepended to PATH really
#      does redirect `phpize --version` to report the 8.3 API.
#   5. PEAR does NOT honor PHP_PEAR_PHPIZE_BIN (catches the earlier
#      wrong-fix pattern from bd02fff).
#
# If any of these contract points silently change (PEAR version bump,
# distro repackaging, etc.), this test file fails and the install.wsl.sh
# fix needs to be revisited BEFORE deploying to production.
#
# Skip policy:
#   - Mac (darwin): different mechanism entirely (brew per-version pecl).
#   - /usr/bin/pecl absent: skipped; the fix doesn't apply.
#   - PEAR .php files absent (PECL not installed): skipped.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

# Skip on Mac — brew ships per-version pecl binaries, different plumbing.
if [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
    echo "  ⏭  skipped — macOS uses brew per-version pecl, different mechanism"
    echo "0/0 passed"
    exit 0
fi

# Skip if pecl isn't installed — we don't require PECL on CI runners.
if [[ ! -f /usr/bin/pecl ]]; then
    echo "  ⏭  skipped — /usr/bin/pecl not installed on this host"
    echo "0/0 passed"
    exit 0
fi

PEAR_CONFIG="/usr/share/php/PEAR/Config.php"
PEAR_BUILDER="/usr/share/php/PEAR/Builder.php"

echo
echo "═══ /usr/bin/pecl honors PHP_PEAR_PHP_BIN ═══"

# The first line of defense — pecl's shell script must have the
# PHP_PEAR_PHP_BIN branch we pin the target PHP binary through.
assert_pattern_present "/usr/bin/pecl" 'PHP_PEAR_PHP_BIN' \
    "/usr/bin/pecl reads PHP_PEAR_PHP_BIN (bedrock of the fix)"

assert_pattern_present "/usr/bin/pecl" 'exec .?PHP' \
    "/usr/bin/pecl exec's the PHP binary it selected"

echo
echo "═══ PEAR Config.php reads the env vars our fix depends on ═══"

if [[ -f "$PEAR_CONFIG" ]]; then
    # These two env vars are what let us override bin_dir + ext_dir
    # per-invocation without touching the shared .pearrc.
    assert_pattern_present "$PEAR_CONFIG" 'PHP_PEAR_BIN_DIR' \
        "PEAR Config.php reads PHP_PEAR_BIN_DIR from environment"

    assert_pattern_present "$PEAR_CONFIG" 'PHP_PEAR_EXTENSION_DIR' \
        "PEAR Config.php reads PHP_PEAR_EXTENSION_DIR from environment"

    # Red-flag pattern: PHP_PEAR_PHPIZE_BIN was the first (wrong) fix
    # idea — it does not exist in PEAR. If a future contributor adds
    # it back thinking it works, this assertion fires and they get the
    # wake-up call that it's a dead env var.
    assert_pattern_absent "$PEAR_CONFIG" 'PHP_PEAR_PHPIZE_BIN' \
        "PEAR Config.php does NOT honor PHP_PEAR_PHPIZE_BIN (it never has)"
else
    echo "  ⏭  PEAR Config.php absent ($PEAR_CONFIG) — skipping config assertions"
fi

echo
echo "═══ PEAR Builder.php runs phpize via PATH lookup ═══"

# The actual mechanism: Builder.php prepends bin_dir to PATH, then
# executes "phpize" as a bare name. That lookup is where our shim dir
# wins. If Builder.php ever changes to an absolute path, our fix is
# dead — this test will tell us so we can update.
if [[ -f "$PEAR_BUILDER" ]]; then
    assert_pattern_present "$PEAR_BUILDER" '"phpize"' \
        "PEAR Builder.php calls 'phpize' by name (PATH lookup — where our shim wins)"

    assert_pattern_present "$PEAR_BUILDER" "putenv.?'PATH=.*binDir" \
        "PEAR Builder.php prepends bin_dir to PATH — our override target"
else
    echo "  ⏭  PEAR Builder.php absent ($PEAR_BUILDER) — skipping builder assertions"
fi

echo
echo "═══ Per-version phpize binaries report the expected PHP API ═══"

# Sanity check that ondrej still ships phpize8.X binaries AND each
# reports the API number our installer pairs with it. If an apt
# upgrade breaks this invariant (unlikely but possible), our target
# ext dir paths go stale.
_api_for_phpize() {
    /usr/bin/phpize"$1" --version 2>/dev/null \
        | grep -E 'PHP Api' \
        | awk '{print $NF}'
}

for vinfo in "8.3:20230831" "8.4:20240924" "8.5:20250925"; do
    ver="${vinfo%:*}"
    expected="${vinfo#*:}"
    bin="/usr/bin/phpize${ver}"
    if [[ ! -x "$bin" ]]; then
        # Not installed on this host — skip silently (each user picks
        # their own PHP versions).
        continue
    fi
    actual="$(_api_for_phpize "$ver")"
    assert_eq "$actual" "$expected" \
        "phpize${ver} reports PHP API $expected (target for /usr/lib/php/${expected})"
done

echo
echo "═══ Scratch-dir symlink: PATH prepending pins the phpize version ═══"

# This is the core behavioral test. Simulate exactly what the installer
# does: scratch dir with `phpize → phpize8.X`, prepended to PATH.
# Bare `phpize --version` must resolve to the target version.
#
# If this ever stops working (PATH lookup semantics change, symlink
# resolution breaks), our fix is inert — test catches it here instead
# of six hours into a failed bootstrap run.
if [[ -x /usr/bin/phpize8.3 ]]; then
    scratch="$(mktemp -d -t pecl-pin-test.XXXXXX)"
    ln -s /usr/bin/phpize8.3 "$scratch/phpize"

    via_shim="$(PATH="$scratch:$PATH" phpize --version 2>/dev/null \
                 | grep -E 'PHP Api' | awk '{print $NF}')"

    assert_eq "$via_shim" "20230831" \
        "PATH=<scratch>:… with phpize→phpize8.3 symlink → phpize --version says 20230831"

    rm -rf "$scratch"
else
    # Fall back to whichever phpize8.X is present so the test isn't
    # pinned to a single installed PHP version.
    for ver_ph in 8.4 8.5; do
        if [[ -x "/usr/bin/phpize${ver_ph}" ]]; then
            expected_api="$(/usr/bin/phpize${ver_ph} --version 2>/dev/null \
                             | grep -E 'PHP Api' | awk '{print $NF}')"
            scratch="$(mktemp -d -t pecl-pin-test.XXXXXX)"
            ln -s "/usr/bin/phpize${ver_ph}" "$scratch/phpize"
            via_shim="$(PATH="$scratch:$PATH" phpize --version 2>/dev/null \
                         | grep -E 'PHP Api' | awk '{print $NF}')"
            assert_eq "$via_shim" "$expected_api" \
                "PATH=<scratch>:… with phpize→phpize${ver_ph} symlink redirects to API $expected_api"
            rm -rf "$scratch"
            break
        fi
    done
fi

echo
summary
