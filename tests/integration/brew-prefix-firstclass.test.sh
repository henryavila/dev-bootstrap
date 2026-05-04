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
# Match both the legacy `BREW_DECISION_METHOD="prompt"` (bare global assign)
# and the current eval-friendly `printf 'BREW_DECISION_METHOD=%q\n' "prompt"`.
# Pattern matches either: `BREW_DECISION_METHOD=` followed by anything ending
# in `"<method>"` on the same line.
assert_pattern_present "$TOPIC" 'BREW_DECISION_METHOD=.*"prompt"' \
    "ladder rung 4: prompt (TTY interactive choice)"
assert_pattern_present "$TOPIC" 'BREW_DECISION_METHOD=.*"default"' \
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

# ---------------------------------------------------------------------
# EXECUTION-LEVEL — re-runs the actual installer in an isolated env
# ---------------------------------------------------------------------
#
# REGRESSION GUARD (added 2026-05-04 after Camada 4 follow-up incident).
# The static greps above prove the strings exist but cannot detect
# subshell-scope bugs: if `decide_brew_prefix` is invoked via `$(...)`
# and tries to set globals as a side effect, those globals never reach
# the parent shell — and `set -u` in install.mac.sh aborts the run with
# "BREW_DECISION_METHOD: unbound variable". The static-pattern suite
# was 29/29 green WHILE the script was broken on every Mac with brew
# already installed. This block exercises the actual code path so the
# bug class cannot return.
#
# Strategy:
#   1. Spawn a fake `brew` in a tempdir + prepend to PATH.
#      `lib/detect-brew.sh` walks PATH first, so this wins rung 1
#      ("detected_existing") deterministically.
#   2. Override DEV_BOOTSTRAP_STATE_DIR so we don't clobber the user's
#      real state.env at ~/.config/dev-bootstrap.
#   3. Run install.mac.sh standalone, capture exit code + log.
#   4. Assert exit 0, no "unbound variable" anywhere, and state.env
#      ends up populated with method=detected_existing.
echo
echo "═══ EXECUTION — install.mac.sh end-to-end with fake brew (regression) ═══"

EXEC_TMP="$(mktemp -d -t brew-prefix-exec.XXXXXX)"
# `trap 'cmd' EXIT` only allows one trap per shell — append the cleanup
# without clobbering the existing assert.sh trap by using a function.
cleanup_exec_tmp() { rm -rf "$EXEC_TMP"; }
trap cleanup_exec_tmp EXIT

mkdir -p "$EXEC_TMP/bin"
cat > "$EXEC_TMP/bin/brew" <<'FAKEBREW'
#!/usr/bin/env bash
# Minimal fake brew used by tests/integration/brew-prefix-firstclass.test.sh.
# Honors `--prefix` (returns the fake prefix dir) and `list --formula <p>`
# (always exit 0 = "already installed", so install.mac.sh never tries to
# fetch real packages).
case "${1:-}" in
    --prefix)
        printf '%s\n' "$FAKE_BREW_PREFIX"
        ;;
    list)
        # `brew list --formula <name>` — exit 0 means installed
        exit 0
        ;;
    install)
        # Should not be reached when `list` always succeeds, but stay quiet
        exit 0
        ;;
    *)
        # Any other command: succeed silently
        exit 0
        ;;
esac
FAKEBREW
chmod +x "$EXEC_TMP/bin/brew"

# Provide a non-canonical fake prefix so the "is_canonical" branch in
# install.mac.sh (line ~241) gets exercised — closer to what M2 hits.
FAKE_BREW_PREFIX="$EXEC_TMP/fake-prefix"
mkdir -p "$FAKE_BREW_PREFIX/opt/gettext/bin"
export FAKE_BREW_PREFIX

EXEC_LOG="$EXEC_TMP/run.log"
EXEC_STATE="$EXEC_TMP/state-dir"

if PATH="$EXEC_TMP/bin:$PATH" \
   DEV_BOOTSTRAP_STATE_DIR="$EXEC_STATE" \
   bash "$ROOT/topics/00-core/install.mac.sh" >"$EXEC_LOG" 2>&1; then
    pass "install.mac.sh exits 0 with brew already on PATH (regression: was 'unbound variable')"
else
    rc=$?
    fail "install.mac.sh exited $rc — log follows:"
    sed 's/^/      /' "$EXEC_LOG" >&2
fi

# Hard regression guard: bash itself emits "unbound variable" to stderr
# on `set -u` failure. Even if exit code happens to be 0, this string
# in the log means the bug is back.
if grep -q 'unbound variable' "$EXEC_LOG" 2>/dev/null; then
    fail "log contains 'unbound variable' (subshell-scope bug regression)"
    grep -n 'unbound variable' "$EXEC_LOG" | sed 's/^/      /' >&2
else
    pass "log free of 'unbound variable' errors"
fi

# state.env must be populated — proves the state_record_brew_prefix call
# was actually reached (it lives AFTER the failing line in the broken version).
if [[ -f "$EXEC_STATE/state.env" ]]; then
    pass "state.env created at \$DEV_BOOTSTRAP_STATE_DIR (state_record_brew_prefix reached)"

    if grep -qE '^BREW_PREFIX_DECISION_METHOD="detected_existing"' "$EXEC_STATE/state.env"; then
        pass "state.env records method=detected_existing (rung 1 wired correctly)"
    else
        fail "state.env should record method=detected_existing — got:"
        sed -n 's/^/      /p' "$EXEC_STATE/state.env" >&2
    fi

    expected_prefix="$FAKE_BREW_PREFIX"
    if grep -qE "^BREW_PREFIX=\"${expected_prefix//\//\\/}\"" "$EXEC_STATE/state.env"; then
        pass "state.env records BREW_PREFIX = fake prefix (eval pattern preserved value)"
    else
        fail "state.env BREW_PREFIX != $expected_prefix — got:"
        grep '^BREW_PREFIX=' "$EXEC_STATE/state.env" | sed 's/^/      /' >&2
    fi
else
    fail "state.env missing at $EXEC_STATE/state.env (decision ladder aborted before record)"
fi

# ---------------------------------------------------------------------
# CONTRACT — decide_brew_prefix emits eval-able stdout (no side-effects)
# ---------------------------------------------------------------------
#
# Source the function in isolation and call it via `$(...)` to confirm
# the parent shell's BREW_DECISION_METHOD / BREW_PREFIX_CHOSEN come
# from `eval "$(...)"`, NOT from in-function global assignment. This
# is the architectural contract — break it (e.g. someone re-introduces
# `BREW_DECISION_METHOD="x"` inside the function) and these asserts
# catch it.
echo
echo "═══ CONTRACT — decide_brew_prefix is eval-friendly (no side-effect-only writes) ═══"

# Static read of the function body — every assignment to BREW_DECISION_METHOD
# inside the function MUST go through `printf` (eval-able) rather than be a
# bare assignment, otherwise the value won't propagate out of the subshell.
# Allow ONE legal exception: if the ladder ever wants a local cache, it must
# use `local BREW_DECISION_METHOD=…`. We forbid the bare-global form.
if grep -nE '^[[:space:]]+BREW_DECISION_METHOD=' "$TOPIC" \
        | grep -v 'local ' | grep -v '^[[:space:]]*#' \
        > /dev/null; then
    fail "decide_brew_prefix has bare BREW_DECISION_METHOD= assignment (will be lost in subshell)"
    grep -nE '^[[:space:]]+BREW_DECISION_METHOD=' "$TOPIC" | sed 's/^/      /' >&2
else
    pass "no bare BREW_DECISION_METHOD= assignments inside decide_brew_prefix (subshell-safe)"
fi

# The function MUST emit BREW_DECISION_METHOD on stdout via printf+%q,
# which is the only way to land it in the caller's scope through eval.
assert_pattern_present "$TOPIC" "printf 'BREW_DECISION_METHOD=%q" \
    "decide_brew_prefix emits BREW_DECISION_METHOD via printf %q (eval-able)"
assert_pattern_present "$TOPIC" "printf 'BREW_PREFIX_CHOSEN=%q" \
    "decide_brew_prefix emits BREW_PREFIX_CHOSEN via printf %q (eval-able)"

# Caller must use eval, not plain command substitution, to read those.
assert_pattern_present "$TOPIC" 'eval "\$__decide_out"' \
    "caller uses eval to source decide_brew_prefix output (subshell-safe contract)"

# Old anti-pattern that caused the original incident: capturing only the
# prefix via `chosen_prefix="$(decide_brew_prefix)"` and then reading
# BREW_DECISION_METHOD from the parent. If that line ever returns,
# this catches it.
if grep -qE '^chosen_prefix="\$\(decide_brew_prefix\)"$' "$TOPIC"; then
    fail "anti-pattern restored: chosen_prefix=\$(decide_brew_prefix) — globals lost in subshell"
else
    pass "no chosen_prefix=\$(decide_brew_prefix) anti-pattern (eval contract preserved)"
fi

summary
