#!/usr/bin/env bash
# tests/integration/brew-prefix-firstclass.test.sh
#
# Camada 4 (Mac §4.7.5): topics/00-core/install.mac.sh must support an
# explicit, persistent choice of Homebrew prefix:
#   - canonical (/opt/homebrew, /usr/local) → official installer
#   - custom path (e.g. /Volumes/External/homebrew) → git clone
#   - persisted in state.env so subsequent runs never re-prompt
#
# Decision ladder ordered by priority (highest first):
#   1. detect-brew.sh wins (already installed → use it)
#   2. state.env (previously recorded BREW_PREFIX from earlier run)
#   3. BREW_CUSTOM_PREFIX env var
#   4. interactive TTY prompt
#   5. silent default /opt/homebrew (non-interactive)
#
# Plus the structural bottle-less warning when prefix is non-canonical
# (D31, D32, D34, D42, Camada 4 implications enumerated for the user).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

TOPIC="$ROOT/topics/00-core/install.mac.sh"
BOOT="$ROOT/bootstrap.sh"

assert_file_exists "$TOPIC" "topics/00-core/install.mac.sh exists"

# ---------------------------------------------------------------------
# Decision ladder structure
# ---------------------------------------------------------------------
echo
echo "═══ topics/00-core/install.mac.sh — decision ladder ═══"

assert_pattern_present "$TOPIC" 'source.*lib/state\.sh' \
    "00-core sources lib/state.sh"

assert_pattern_present "$TOPIC" 'decide_brew_prefix' \
    "00-core defines decide_brew_prefix function"

# Ladder priorities present, named for grep-able auditing
assert_pattern_present "$TOPIC" 'detected_existing' \
    "ladder rung 1: detected_existing (brew already on disk)"
assert_pattern_present "$TOPIC" 'state_replay' \
    "ladder rung 2: state_replay (state.env recorded a previous prefix)"
assert_pattern_present "$TOPIC" 'env_var' \
    "ladder rung 3: env_var (BREW_CUSTOM_PREFIX)"
assert_pattern_present "$TOPIC" 'BREW_DECISION_METHOD="prompt"' \
    "ladder rung 4: prompt (TTY interactive choice)"
assert_pattern_present "$TOPIC" 'BREW_DECISION_METHOD="default"' \
    "ladder rung 5: default (silent /opt/homebrew)"

# BREW_CUSTOM_PREFIX env var is the documented opt-in mechanism
assert_pattern_present "$TOPIC" 'BREW_CUSTOM_PREFIX' \
    "00-core honors BREW_CUSTOM_PREFIX env var"

# ---------------------------------------------------------------------
# Persistence — every accepted prefix gets recorded
# ---------------------------------------------------------------------
echo
echo "═══ persistence — state_record_brew_prefix wired in ═══"

# Should be called in every code path that decides a prefix
record_count="$(grep -c 'state_record_brew_prefix' "$TOPIC" 2>/dev/null || echo 0)"
if [[ "$record_count" -ge 3 ]]; then
    pass "state_record_brew_prefix called in $record_count code paths (≥3 expected: existing, canonical-install, custom-install)"
else
    fail "state_record_brew_prefix should be called in every code path that resolves a prefix (got $record_count)"
fi

# ---------------------------------------------------------------------
# Custom-prefix install path
# ---------------------------------------------------------------------
echo
echo "═══ custom-prefix install (untar-anywhere via git clone) ═══"

assert_pattern_present "$TOPIC" 'install_brew_at_custom_prefix' \
    "00-core defines install_brew_at_custom_prefix function"

# Untar-anywhere = git clone of Homebrew/brew (NOT the curl|bash installer)
assert_pattern_present "$TOPIC" 'git clone .* https://github.com/Homebrew/brew\.git' \
    "custom prefix uses git clone of Homebrew/brew (untar-anywhere pattern)"

# brew update --force after clone primes formula + bottle caches
assert_pattern_present "$TOPIC" 'brew update --force' \
    "custom prefix install primes formula caches via brew update --force"

# zsh completion dir mode fix (compinit refuses go-w)
assert_pattern_present "$TOPIC" 'chmod -R go-w.*share/zsh' \
    "custom prefix install fixes share/zsh permissions for compinit"

# Refuse to clobber existing non-empty directory
assert_pattern_present "$TOPIC" 'refusing to install brew at .* — directory exists' \
    "custom-prefix install refuses to overwrite a non-empty existing directory"

# ---------------------------------------------------------------------
# Canonical-prefix install path remains the official installer
# ---------------------------------------------------------------------
echo
echo "═══ canonical-prefix install (official curl|bash installer) ═══"

assert_pattern_present "$TOPIC" 'raw\.githubusercontent\.com/Homebrew/install/HEAD/install\.sh' \
    "canonical prefix uses the official Homebrew installer"

# Both /opt/homebrew and /usr/local are recognized canonical
assert_pattern_present "$TOPIC" '/opt/homebrew\|/usr/local' \
    "canonical-prefix branch names /opt/homebrew + /usr/local"

# ---------------------------------------------------------------------
# Bottle-less warning (Task #7) — structural references to D31..D42
# ---------------------------------------------------------------------
echo
echo "═══ bottle-less warning (custom prefix implications) ═══"

assert_pattern_present "$TOPIC" 'emit_custom_prefix_warning' \
    "00-core defines emit_custom_prefix_warning function"

# Each decision ID we care about is named in the warning so grep-blame
# from a future incident can find the relevant memory.
assert_pattern_present "$TOPIC" 'D31' "warning references D31 (bottle-less / 3-tier retry)"
assert_pattern_present "$TOPIC" 'D32' "warning references D32 (/etc/paths.d)"
assert_pattern_present "$TOPIC" 'D34' "warning references D34 (PECL 3-path)"
assert_pattern_present "$TOPIC" 'D42' "warning references D42 (LaunchDaemon hardening)"
assert_pattern_present "$TOPIC" 'lib/launch-wrapper\.sh' \
    "warning references lib/launch-wrapper.sh (Camada 4 user-scope wrappers)"

# Warning explicitly states it is NON-blocking in non-TTY (CI-safe)
assert_pattern_present "$TOPIC" '\[\[ -t 0 \]\]' \
    "warning checks TTY before prompting (non-blocking in CI)"
assert_pattern_present "$TOPIC" 'NON_INTERACTIVE' \
    "warning honors NON_INTERACTIVE env var"

# Anti-pattern: must not bypass the warn just because brew_prefix is set
assert_pattern_absent "$TOPIC" '^[[:space:]]*emit_custom_prefix_warning[[:space:]]*$' \
    'emit_custom_prefix_warning is always called inside if/|| (return value matters)'

# ---------------------------------------------------------------------
# bootstrap.sh sources state.sh and calls state_load
# ---------------------------------------------------------------------
echo
echo "═══ bootstrap.sh — state.sh wiring ═══"

assert_pattern_present "$BOOT" 'source.*lib/state\.sh' \
    "bootstrap.sh sources lib/state.sh"
assert_pattern_present "$BOOT" 'state_load' \
    "bootstrap.sh calls state_load before topics run"

# state_load must come BEFORE the first run_topic invocation (so 00-core
# sees previously-persisted BREW_PREFIX)
state_load_line="$(grep -nE '^state_load' "$BOOT" | head -1 | cut -d: -f1)"
first_run_topic_line="$(grep -nE '^[[:space:]]*run_topic[[:space:]]' "$BOOT" | head -1 | cut -d: -f1)"
if [[ -n "$state_load_line" ]] && [[ -n "$first_run_topic_line" ]]; then
    if [[ "$state_load_line" -lt "$first_run_topic_line" ]]; then
        pass "state_load (line $state_load_line) precedes first run_topic (line $first_run_topic_line)"
    else
        fail "state_load must come before run_topic (got state_load=$state_load_line, run_topic=$first_run_topic_line)"
    fi
else
    fail "could not locate both state_load and run_topic in bootstrap.sh"
fi

summary
