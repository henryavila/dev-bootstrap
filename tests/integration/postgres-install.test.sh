#!/usr/bin/env bash
# tests/integration/postgres-install.test.sh
#
# Coverage for the INCLUDE_POSTGRES opt-in (60-web-stack), revised after
# adversarial review (3 paralelos reviewers — code-reviewer +
# silent-failure-hunter + pr-test-analyzer). Pre-revision suite was 30
# contract assertions and revealed 6 mutation paths that still passed.
# This revision adds:
#
#   - Anchored regexes that can only match the load-bearing line, not
#     a comment or sibling string elsewhere in the file (mutation-
#     resistant — anchored regexes prevent false-positive matches on comments or sibling strings).
#   - Layer 2 EXECUTION assertions: run the script in a subshell with
#     controlled inputs and assert exit codes / side-effects. Targets
#     the top-of-script guards (version validation, $USER sanitization,
#     non-apt-distro detection) which abort before any heavy mocking
#     would be needed.
#   - Layer 3 SOURCE assertions: source the script's helper functions
#     in isolation and exercise them with controlled inputs (port
#     detection, version-list parsing).
#
# Tests are CONTRACT-level for behaviors that mutate real system state
# (apt repos, brew installs, launchd plists, role/db creation) — those
# stay end-to-end-validated on the host where the bootstrap actually
# ran. Full PATH-shim execution tests for the install/service paths are
# DEFERRED — they'd need ~10 shims (brew, apt-get, dpkg, systemctl, ss,
# lsof, pg_isready, psql, createuser, createdb, sudo, gpg, curl,
# pg_lsclusters) and are tracked as a follow-up.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

PG_SCRIPT="$ROOT/topics/databases/scripts/install-postgres.sh"
MAC_INSTALL="$ROOT/topics/databases/postgresql.sh"
PG_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/postgres-install-test.XXXXXX")"
trap 'rm -rf "$PG_TEST_ROOT"' EXIT INT TERM

assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

# Block-scoped grep — verifies that line2 appears within the next 5
# lines after line1. Used for "gate line followed by bash invocation"
# patterns where a comment or info() call may legitimately sit between
# them. Window of 5 is generous enough to allow doc/info but tight
# enough to require the gate-and-action coupling.
assert_block_present() {
    local file="$1" line1="$2" line2="$3" msg="$4"
    if awk -v l1="$line1" -v l2="$line2" '
        $0 ~ l1 { found=NR }
        found && NR > found && NR <= found+5 && $0 ~ l2 { print "MATCH"; exit }
    ' "$file" 2>/dev/null | grep -q "MATCH"; then
        pass "$msg"
    else
        fail "$msg (block '$line1' → '$line2' (within 5 lines) not found in $file)"
    fi
}

echo
echo "═══ Layer 1 — file-level invariants ═══"

assert_file_exists "$PG_SCRIPT" "install-postgres.sh exists"

if [[ -x "$PG_SCRIPT" ]]; then pass "install-postgres.sh is executable"
else fail "install-postgres.sh is not executable"; fi

if bash -n "$PG_SCRIPT" 2>/dev/null; then
    pass "install-postgres.sh has valid bash syntax"
else
    fail "install-postgres.sh — bash -n failed"
fi

# Check no bash 4+ idioms (mapfile / readarray / declare -A / ${var,,})
# leaked in the rewrite — the lint test enforces this globally but we
# add a script-specific assertion for fast-feedback.
if ! grep -qE '^[[:space:]]*(mapfile|readarray)\b' "$PG_SCRIPT" \
   && ! grep -qE 'declare -A\b' "$PG_SCRIPT" \
   && ! grep -qE '\$\{[a-zA-Z_]+,,\}' "$PG_SCRIPT"; then
    pass "no bash 4+ idioms (mapfile/readarray/declare -A/lower-expansion)"
else
    fail "found bash 4+ idiom — Mac (3.2) bootstrap will break"
fi

echo
echo "═══ Layer 2a — input validation guards (anchored + executed) ═══"

# CONTRACT: numeric guard exists with hard-stop semantics. After review,
# regex was tightened to [10-29] (not [0-9]{1,3}); fail must be followed
# by exit 1 because lib/log.sh:fail() does NOT exit by itself.
assert_pattern_present "$PG_SCRIPT" '=~ \^\(1\[0-9\]\|2\[0-9\]\)\$' \
    "POSTGRES_VERSION regex tightened to plausible majors (10-29)"

assert_block_present "$PG_SCRIPT" \
    'fail "POSTGRES_VERSION=' \
    'exit 1' \
    "POSTGRES_VERSION fail is followed by exit 1 (lib/log.sh:fail doesn't exit on its own)"

# CONTRACT: $USER sanitizer exists.
assert_pattern_present "$PG_SCRIPT" '=~ \^\[a-zA-Z_\]\[a-zA-Z0-9_-\]' \
    "\$USER sanitizer regex (defense against env-var injection into psql -tAc)"

assert_block_present "$PG_SCRIPT" \
    "fail \"refusing to use suspicious USER" \
    'exit 1' \
    "\$USER fail is followed by exit 1"

# CONTRACT: capture caller intent BEFORE defaulting (cross-major detect).
assert_pattern_present "$PG_SCRIPT" 'POSTGRES_VERSION_REQUESTED="\$\{POSTGRES_VERSION:-\}"' \
    "POSTGRES_VERSION_REQUESTED captured BEFORE default — explicit-vs-default needed for cross-major hard-stop"

# EXECUTION: bad POSTGRES_VERSION exits non-zero IMMEDIATELY at the
# guard. Mutation-resistance: a regression that drops `exit 1` after
# `fail` would leave exit_rc still non-zero (the script eventually
# aborts on `${BREW_BIN:?}`), but stderr would then ALSO contain
# downstream artifacts. Validate both: (a) the guard message present,
# (b) NO post-guard step ran (no `BREW_BIN: …`, no apt error, no OS
# dispatch noise).
_assert_aborts_at_guard() {
    local label="$1" stderr="$2" expected_msg="$3"
    if echo "$stderr" | grep -qE "$expected_msg"; then
        if echo "$stderr" | grep -qE "BREW_BIN: |uname:|apt-get|brew install|launchctl"; then
            fail "EXECUTION: $label — guard message present but downstream steps also ran (mutation: did the exit 1 disappear?)"
        else
            pass "EXECUTION: $label"
        fi
    else
        fail "EXECUTION: $label — expected message not in stderr: ${stderr:0:120}…"
    fi
}

exec_out=""
exec_rc=0
exec_out="$(POSTGRES_VERSION=foo bash "$PG_SCRIPT" 2>&1)" || exec_rc=$?
if [[ $exec_rc -ne 0 ]]; then
    _assert_aborts_at_guard "POSTGRES_VERSION=foo aborts AT the guard (no downstream)" \
        "$exec_out" "POSTGRES_VERSION='foo' invalid"
else
    fail "EXECUTION: POSTGRES_VERSION=foo did not exit non-zero"
fi

exec_out=""
exec_rc=0
exec_out="$(POSTGRES_VERSION=17.2 bash "$PG_SCRIPT" 2>&1)" || exec_rc=$?
if [[ $exec_rc -ne 0 ]]; then
    pass "EXECUTION: POSTGRES_VERSION=17.2 (decimal) rejected"
else
    fail "EXECUTION: decimal version was accepted"
fi

exec_out=""
exec_rc=0
exec_out="$(POSTGRES_VERSION=999 bash "$PG_SCRIPT" 2>&1)" || exec_rc=$?
if [[ $exec_rc -ne 0 ]]; then
    pass "EXECUTION: POSTGRES_VERSION=999 (out-of-range) rejected"
else
    fail "EXECUTION: 999 was accepted (regex too loose?)"
fi

exec_out=""
exec_rc=0
exec_out="$(POSTGRES_VERSION='17; rm -rf /' bash "$PG_SCRIPT" 2>&1)" || exec_rc=$?
if [[ $exec_rc -ne 0 ]] && ! echo "$exec_out" | grep -qE "rm: |No such"; then
    pass "EXECUTION: command-injection attempt in POSTGRES_VERSION rejected (no rm executed)"
else
    fail "EXECUTION: injection POSTGRES_VERSION='17; rm -rf /' may have executed sub-command"
fi

# EXECUTION: bad $USER exits non-zero AT the sanitizer guard.
exec_out=""
exec_rc=0
exec_out="$(USER='bad user' POSTGRES_VERSION=17 bash "$PG_SCRIPT" 2>&1)" || exec_rc=$?
if [[ $exec_rc -ne 0 ]]; then
    _assert_aborts_at_guard "\$USER='bad user' aborts AT sanitizer (no downstream)" \
        "$exec_out" "suspicious USER='bad user'"
else
    fail "EXECUTION: \$USER='bad user' did not exit non-zero"
fi

exec_out=""
exec_rc=0
# Use a heredoc-style assignment to dodge nested-quote parsing pain.
sql_payload="foo'; DROP DATABASE template1; --"
exec_out="$(USER="$sql_payload" POSTGRES_VERSION=17 bash "$PG_SCRIPT" 2>&1)" || exec_rc=$?
if [[ $exec_rc -ne 0 ]]; then
    pass "EXECUTION: \$USER with SQL-injection payload rejected"
else
    fail "EXECUTION: SQL-injection \$USER was accepted"
fi

echo
echo "═══ Layer 2b — cross-major detection (mutation-resistant) ═══"

# Plural helper renames: _postgres_installed_version → _postgres_installed_versions
# (returns ALL installed majors, not just the first).
assert_pattern_present "$PG_SCRIPT" '_postgres_installed_versions\(\)' \
    "helper returns ALL installed majors (renamed plural after review found awk-exit hid parallel-major installs)"

# Mac dpkg single-line awk MUST NOT have `exit` anywhere — the original
# bug was `awk … {print …; exit}` which hid pg16+pg17 parallel installs.
assert_pattern_present "$PG_SCRIPT" "awk -F'@' '/\^postgresql@\[0-9\]\+\\\$/ \\{print \\\$2\\}'" \
    "Mac install-list awk does NOT 'exit' on first match (full enumeration)"

# Parallel-major hard stop.
assert_pattern_present "$PG_SCRIPT" 'Multiple PostgreSQL majors installed' \
    "parallel-major detection emits followup critical"

# Cross-major: explicit-request hard-stop vs silent-default fall-through.
assert_pattern_present "$PG_SCRIPT" 'if \[\[ -n "\$POSTGRES_VERSION_REQUESTED" \]\]' \
    "cross-major branch distinguishes explicit-vs-default request"

assert_pattern_present "$PG_SCRIPT" 'will not auto-downgrade' \
    "explicit-request collision emits hard-stop message (no silent override)"

echo
echo "═══ Layer 2c — port :5432 detection + service start ═══"

# Both detectors must look at the OS user owning the listener (not the
# process basename). Mac path now mirrors Linux semantics.
assert_pattern_present "$PG_SCRIPT" '_port_5432_in_foreign_use' \
    "foreign-port detector function defined"
assert_pattern_present "$PG_SCRIPT" '_port_5432_owner_is_postgres' \
    "postgres-owns-port detector function defined"

# Port conflict uses followup critical (not warn) — surfaces in the
# end-of-bootstrap summary so user can't miss it.
assert_pattern_present "$PG_SCRIPT" 'followup critical "port 5432' \
    "port-conflict diagnostic uses followup critical (not warn)"

assert_pattern_present "$PG_SCRIPT" 'PORT_CONFLICT=1' \
    "PORT_CONFLICT flag set on conflict detection"

assert_pattern_present "$PG_SCRIPT" "pg_isready -h 127.0.0.1 -p 5432" \
    "Linux postgres-port detector falls back to pg_isready when ss omits process owner"
assert_pattern_present "$PG_SCRIPT" 'no response' \
    "Linux postgres-port detector treats pg_isready 'no response' as foreign/unknown listener"

# SERVICE_STARTED flag explicitly tracked (replaces previous fall-through
# behavior where success was assumed from "no warn yet").
assert_pattern_present "$PG_SCRIPT" 'SERVICE_STARTED=0' \
    "SERVICE_STARTED initialized to 0"
assert_pattern_present "$PG_SCRIPT" 'SERVICE_STARTED=1' \
    "SERVICE_STARTED set to 1 only on successful start path"

echo
echo "═══ Layer 2d — Mac path (canonical + custom prefix) ═══"

# Canonical prefix path: brew services start, capture stderr.
assert_pattern_present "$PG_SCRIPT" 'brew_err="\$\("\$BREW_BIN" services start "postgresql@\$\{POSTGRES_VERSION\}" 2>&1' \
    "brew services start captures stderr (no 2>/dev/null swallowing)"

assert_pattern_present "$PG_SCRIPT" 'followup critical "brew services start postgresql' \
    "brew start failure → followup critical (not generic warn)"

# Custom prefix path: launch_wrapper_install_extbrew with versioned label.
assert_pattern_present "$PG_SCRIPT" 'pg_label="com\.\$\{USER\}\.postgresql@\$\{POSTGRES_VERSION\}"' \
    "Mac wrapper label is versioned (com.\$USER.postgresql@N) — distinguishes major versions"

assert_pattern_present "$PG_SCRIPT" 'launch_wrapper_install_extbrew' \
    "launch_wrapper_install_extbrew invoked"

assert_pattern_present "$PG_SCRIPT" '\-\-workdir "\$pg_data_dir"' \
    "wrapper --workdir points at the validated cluster data dir"

# Rollback on wrapper failure (restores brew plist .bak).
assert_pattern_present "$PG_SCRIPT" 'launch_wrapper_teardown "\$pg_label"' \
    "wrapper failure path tears down the partial wrapper plist"

assert_pattern_present "$PG_SCRIPT" 'mv "\$\{pg_brew_plist\}\.bak" "\$pg_brew_plist"' \
    "wrapper failure path restores brew plist from .bak"

echo
echo "═══ Layer 2d.1 — Mac cluster data-dir recovery (execution) ═══"

_run_pg_mac_fixture() {
    local mode="$1"
    local work fake_prefix shim
    work="$(mktemp -d "$PG_TEST_ROOT/mac-${mode}.XXXXXX")"
    fake_prefix="$work/brew"
    shim="$work/shim"
    mkdir -p "$fake_prefix/opt/postgresql@17/bin" "$shim" \
        "$work/wrapper-bin" "$work/launchagents" "$work/launchlogs"

    cat > "$fake_prefix/opt/postgresql@17/bin/postgres" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fake_prefix/opt/postgresql@17/bin/postgres"

    cat > "$fake_prefix/opt/postgresql@17/bin/initdb" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$INITDB_CALLED_FILE"
last=""
for arg in "$@"; do
    last="$arg"
done
mkdir -p "$last"
printf '17\n' > "$last/PG_VERSION"
exit 0
EOF
    chmod +x "$fake_prefix/opt/postgresql@17/bin/initdb"

    cat > "$shim/brew" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" && "${2:-}" == "--formula" ]]; then
    echo "postgresql@17"
    exit 0
fi
echo "unexpected brew args: $*" >&2
exit 1
EOF
    chmod +x "$shim/brew"

    cat > "$shim/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
    chmod +x "$shim/uname"

    cat > "$shim/lsof" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$shim/lsof"

    cat > "$shim/pg_isready" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$shim/pg_isready"

    cat > "$shim/psql" <<'EOF'
#!/usr/bin/env bash
printf '1\n'
exit 0
EOF
    chmod +x "$shim/psql"

    case "$mode" in
        missing)
            ;;
        initialized)
            mkdir -p "$fake_prefix/var/postgresql@17"
            printf '17\n' > "$fake_prefix/var/postgresql@17/PG_VERSION"
            ;;
        dirty)
            mkdir -p "$fake_prefix/var/postgresql@17"
            printf 'not postgres data\n' > "$fake_prefix/var/postgresql@17/README"
            ;;
        notdir)
            mkdir -p "$fake_prefix/var"
            printf 'not a directory\n' > "$fake_prefix/var/postgresql@17"
            ;;
        initdbfail)
            cat > "$fake_prefix/opt/postgresql@17/bin/initdb" <<'EOF'
#!/usr/bin/env bash
echo "simulated initdb failure" >&2
exit 42
EOF
            chmod +x "$fake_prefix/opt/postgresql@17/bin/initdb"
            ;;
        *)
            fail "unknown pg mac fixture mode: $mode"
            ;;
    esac

    local rc=0
    INITDB_CALLED_FILE="$work/initdb.called" \
    PATH="$shim:/usr/bin:/bin:/usr/sbin:/sbin" \
    BREW_BIN="$shim/brew" \
    BREW_PREFIX="$fake_prefix" \
    POSTGRES_VERSION=17 \
    USER=pgtest \
    LAUNCH_WRAPPER_DRY_RUN=1 \
    LAUNCH_WRAPPER_BIN_DIR="$work/wrapper-bin" \
    LAUNCH_WRAPPER_PLIST_DIR="$work/launchagents" \
    LAUNCH_WRAPPER_LOG_DIR="$work/launchlogs" \
        bash "$PG_SCRIPT" > "$work/stdout" 2> "$work/stderr" || rc=$?
    printf '%s\n' "$rc" > "$work/rc"
    printf '%s\n' "$work"
}

fixture="$(_run_pg_mac_fixture missing)"
fixture_rc="$(cat "$fixture/rc")"
if [[ "$fixture_rc" -eq 0 ]] \
   && [[ -f "$fixture/initdb.called" ]] \
   && [[ -f "$fixture/brew/var/postgresql@17/PG_VERSION" ]]; then
    pass "EXECUTION: Mac installed formula with missing data dir runs initdb before wrapper"
else
    fail "EXECUTION: missing Mac postgres data dir was not initialized (rc=$fixture_rc)"
fi

fixture="$(_run_pg_mac_fixture initialized)"
fixture_rc="$(cat "$fixture/rc")"
if [[ "$fixture_rc" -eq 0 ]] && [[ ! -f "$fixture/initdb.called" ]]; then
    pass "EXECUTION: initialized Mac data dir does not run initdb again"
else
    fail "EXECUTION: initialized Mac data dir should be idempotent (rc=$fixture_rc)"
fi

fixture="$(_run_pg_mac_fixture dirty)"
fixture_rc="$(cat "$fixture/rc")"
fixture_out="$(cat "$fixture/stdout" "$fixture/stderr" 2>/dev/null)"
if [[ "$fixture_rc" -ne 0 ]] \
   && [[ ! -f "$fixture/initdb.called" ]] \
   && echo "$fixture_out" | grep -q "not an initialized PostgreSQL data directory"; then
    pass "EXECUTION: non-empty uninitialized Mac data dir hard-stops without clobber"
else
    fail "EXECUTION: dirty uninitialized Mac data dir was not rejected safely (rc=$fixture_rc)"
fi

fixture="$(_run_pg_mac_fixture notdir)"
fixture_rc="$(cat "$fixture/rc")"
fixture_out="$(cat "$fixture/stdout" "$fixture/stderr" 2>/dev/null)"
if [[ "$fixture_rc" -ne 0 ]] \
   && [[ ! -f "$fixture/initdb.called" ]] \
   && echo "$fixture_out" | grep -q "is not a directory"; then
    pass "EXECUTION: Mac data-dir path that is a file hard-stops"
else
    fail "EXECUTION: Mac data-dir file path was not rejected safely (rc=$fixture_rc)"
fi

fixture="$(_run_pg_mac_fixture initdbfail)"
fixture_rc="$(cat "$fixture/rc")"
fixture_out="$(cat "$fixture/stdout" "$fixture/stderr" 2>/dev/null)"
if [[ "$fixture_rc" -ne 0 ]] \
   && echo "$fixture_out" | grep -q "initdb for postgresql@17 failed"; then
    pass "EXECUTION: Mac initdb failure exits non-zero with diagnostic"
else
    fail "EXECUTION: Mac initdb failure was not surfaced (rc=$fixture_rc)"
fi

assert_pattern_present "$PG_SCRIPT" 'pg_data_dir="\$\(_pg_data_dir\)"' \
    "Mac service path stores validated data dir in pg_data_dir"

assert_pattern_present "$PG_SCRIPT" '\-\-workdir "\$pg_data_dir"' \
    "wrapper --workdir uses validated pg_data_dir variable"

echo
echo "═══ Layer 2e — Linux path (PGDG + systemd correctness) ═══"

# WSL-without-systemd: detection via PID 1, NOT via systemctl --version.
assert_pattern_present "$PG_SCRIPT" '_systemd_is_pid1' \
    "systemd-as-PID-1 detector defined (replaces inverted systemctl --version chain)"

assert_pattern_present "$PG_SCRIPT" 'ps -p 1 -o comm= 2>/dev/null' \
    "_systemd_is_pid1 inspects PID 1 process name (correct semantic)"

assert_pattern_present "$PG_SCRIPT" 'if ! _systemd_is_pid1' \
    "WSL-without-systemd guard fires when systemd is NOT PID 1"

# Cluster detection via pg_lsclusters (vs guessing main).
assert_pattern_present "$PG_SCRIPT" 'pg_lsclusters --no-header' \
    "Linux uses pg_lsclusters to discover clusters (not hardcoded 'main')"

assert_pattern_present "$PG_SCRIPT" 'no cluster exists' \
    "no-cluster case emits actionable followup critical"

# T-006: install starts the unit for role/db setup but does not force-enable
# at boot (services.default owns that). Start errors are still captured.
assert_pattern_present "$PG_SCRIPT" 'no longer force-enables' \
    "install does not force-enable postgres at boot (services.default owns enable)"

assert_pattern_present "$PG_SCRIPT" 'start_err="\$\(sudo systemctl start "\$unit" 2>&1\)"' \
    "systemctl start captures stderr"

assert_pattern_present "$PG_SCRIPT" 'followup critical "systemctl start' \
    "systemctl start failure → followup critical"

# PGDG keyring atomic write (tempfile + mv) — protects against partial-
# failure corrupt-keyring lockout.
assert_pattern_present "$PG_SCRIPT" 'tmp_key=\$\(sudo mktemp\)' \
    "keyring written via mktemp tempfile"

assert_pattern_present "$PG_SCRIPT" 'sudo mv "\$tmp_key" "\$KEYRING"' \
    "keyring atomically renamed only after successful dearmor"

assert_pattern_present "$PG_SCRIPT" 'sudo gpg --show-keys "\$KEYRING"' \
    "keyring re-validated on re-run (catches corrupt files from prior partial failures)"

# apt-get update unconditional + apt-get install captures stderr.
assert_pattern_present "$PG_SCRIPT" 'sudo apt-get update -qq' \
    "apt-get update runs unconditionally (insurance against partial state)"

assert_pattern_present "$PG_SCRIPT" 'apt_err="\$\(sudo apt-get install' \
    "apt-get install captures stderr"

assert_pattern_present "$PG_SCRIPT" 'followup critical "apt-get install' \
    "apt-get install failure → followup critical with codename hint"

# Defense against PHP-recommends infection (D43 family).
assert_pattern_present "$PG_SCRIPT" '[-]-no-install-recommends' \
    "apt install uses --no-install-recommends (D43 defense)"

# Non-Debian distro guard.
assert_pattern_present "$PG_SCRIPT" 'requires Debian/Ubuntu \(apt \+ dpkg\)' \
    "non-Debian distro guard emits clear followup before downstream apt fails cryptically"

echo
echo "═══ Layer 2f — pristine-only role/db (split per Mac+Linux) ═══"

# Both OSes split role and db checks INDEPENDENTLY (previously Linux
# bundled them, leaving half-applied state un-repaired on re-run).
assert_pattern_present "$PG_SCRIPT" "SELECT 1 FROM pg_roles WHERE rolname='\\\$USER'" \
    "role-existence query (parametric on \$USER, sanitized at top)"

assert_pattern_present "$PG_SCRIPT" "SELECT 1 FROM pg_database WHERE datname='\\\$USER'" \
    "database-existence query"

# Linux block must check role and db SEPARATELY (mirrors Mac).
# Count occurrences of pg_roles + pg_database queries — should be 2 each
# (Mac block + Linux block).
roles_count=$(grep -cE "SELECT 1 FROM pg_roles" "$PG_SCRIPT")
db_count=$(grep -cE "SELECT 1 FROM pg_database" "$PG_SCRIPT")
if [[ "$roles_count" -ge 2 ]] && [[ "$db_count" -ge 2 ]]; then
    pass "pg_roles + pg_database checked independently on BOTH OSes ($roles_count role queries, $db_count db queries)"
else
    fail "expected 2+ each of pg_roles/pg_database queries (Mac + Linux); got $roles_count/$db_count"
fi

# createuser/createdb capture stderr — no more "may already exist" lies.
assert_pattern_present "$PG_SCRIPT" 'role_err="\$\(createuser -s "\$USER" 2>&1\)"' \
    "Mac createuser captures stderr (replaces the 2>/dev/null + 'may already exist' lie)"

assert_pattern_present "$PG_SCRIPT" 'role_err="\$\(sudo -u postgres createuser -s "\$USER" 2>&1\)"' \
    "Linux createuser captures stderr"

# Verify the misleading "may already exist" message is GONE from
# user-facing strings (a single mention in the header doc is OK — that
# explains the fix). Filter out comment lines before checking.
non_comment_hits=$(grep -E 'may already exist' "$PG_SCRIPT" | grep -vE '^[[:space:]]*#' | wc -l | tr -d ' ')
if [[ "$non_comment_hits" -eq 0 ]]; then
    pass "'may already exist' lie removed from user-facing output (pristine guard makes it structurally impossible)"
else
    fail "'may already exist' still appears in $non_comment_hits non-comment line(s)"
fi

echo
echo "═══ Layer 2g — PG_READY flag gates the success banner ═══"

assert_pattern_present "$PG_SCRIPT" 'PG_READY=0' \
    "PG_READY initialized to 0"

assert_pattern_present "$PG_SCRIPT" 'PG_READY=1' \
    "PG_READY set to 1 ONLY when role/db DDL succeeded"

assert_pattern_present "$PG_SCRIPT" 'if \[\[ "\$PG_READY" == "1" \]\]; then' \
    "success banner gated on PG_READY=1"

assert_pattern_present "$PG_SCRIPT" 'completed but not fully usable' \
    "non-ready case prints honest 'not fully usable' + exits non-zero"

# Wait timeout bumped 15 → 30 (cold-start tolerance).
assert_pattern_present "$PG_SCRIPT" '_wait_postgres_ready 30' \
    "wait timeout 30s (was 15s — cold systemd + initdb need more)"

assert_pattern_present "$PG_SCRIPT" 'followup critical "postgres did not become ready' \
    "wait timeout escalates to followup critical (not bare warn)"

echo
echo "═══ Layer 3 — install.{mac,wsl}.sh wiring (anchored, mutation-resistant) ═══"

# Per test-analyzer feedback: previous regex matched both the [[ -x ]]
# check line AND the bash invocation line, but each independently. So
# deleting the bash line still passed. Anchor to the gate-then-bash
# block.
# Post-migration: postgres lives in databases/postgresql.sh (type:custom wrapper).
# Bundle selection is the gate (no INCLUDE_*); major version comes from
# POSTGRES_VERSION. The wrapper invokes scripts/install-postgres.sh.
assert_pattern_present "$MAC_INSTALL" 'POSTGRES_VERSION' \
    "postgresql.sh: reads POSTGRES_VERSION"
assert_pattern_present "$MAC_INSTALL" 'bash .*install-postgres\.sh' \
    "postgresql.sh: invokes scripts/install-postgres.sh"

echo
echo "═══ Layer 5 — README + SPEC docs ═══"

assert_pattern_present "$ROOT/README.md" 'INCLUDE_POSTGRES' \
    "README.md mentions INCLUDE_POSTGRES"

assert_pattern_present "$ROOT/README.md" 'POSTGRES_VERSION' \
    "README.md mentions POSTGRES_VERSION"

assert_pattern_present "$ROOT/docs/SPEC.md" 'INCLUDE_POSTGRES' \
    "docs/SPEC.md mentions INCLUDE_POSTGRES"

assert_pattern_present "$ROOT/docs/SPEC.md" 'POSTGRES_VERSION' \
    "docs/SPEC.md mentions POSTGRES_VERSION"

echo
summary
