#!/usr/bin/env bash
# tests/integration/services.test.sh
#
# Contract suite for `mesh services` (initiative mesh-services) — the unified,
# cross-platform service control plane (2-bit model: active × enabled).
#
# Built TDD across T-001..T-006; this file is the deterministic exit-gate
# (G-1 / G-3). It grows one block per task. Current coverage:
#
#   T-001 — the service registry: bash descriptor modules in
#           scripts/lib/services/registry/<id>.sh + the aggregator
#           scripts/lib/services/registry.sh that resolves them for the
#           current OS into machine-readable rows
#               id|display|aliases|owner|kind|scope|target
#           OS is stubbed via MESH_SERVICES_OS (mirrors clean's MESH_CLEAN_OS);
#           the descriptor dir is swapped via MESH_SERVICES_REGISTRY_DIR
#           (mirrors MESH_CLEANERS_DIR) so edge cases use hermetic fixtures.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
AGG="$REPO_ROOT/scripts/lib/services/registry.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-services.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# Resolve the registry for a stubbed OS against the REAL shipped descriptors.
resolve() { MESH_SERVICES_OS="$1" NO_COLOR=1 bash "$AGG"; }
# Same, but against a hermetic fixture descriptor dir.
resolve_in() { MESH_SERVICES_OS="$1" MESH_SERVICES_REGISTRY_DIR="$2" NO_COLOR=1 bash "$AGG"; }

# ─── T-001 ───────────────────────────────────────────────────────────────────

# ─── Case 1: WSL resolves curated services to their systemd units ────────────
out="$(resolve wsl 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 1a: aggregator exits 0 on wsl"
assert_contains "$out" "mysql|MySQL|mysqld|databases|systemd|system|mysql" \
    "Case 1b: mysql resolves to the wsl systemd system unit (full row)"
assert_contains "$out" "redis|Redis|redis-server|databases|systemd|system|redis-server" \
    "Case 1c: redis resolves to the wsl systemd unit redis-server (apt pkg name)"

# ─── Case 2: mac resolves the same services to their brew formulae ───────────
out="$(resolve mac 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 2a: aggregator exits 0 on mac"
assert_contains "$out" "mysql|MySQL|mysqld|databases|brew||mysql" \
    "Case 2b: mysql resolves to the mac brew formula (empty scope)"
assert_contains "$out" "redis|Redis|redis-server|databases|brew||redis" \
    "Case 2c: redis resolves to the mac brew formula"

# ─── Case 3: native Linux falls back to the systemd (wsl) mapping ────────────
out="$(resolve linux 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 3a: aggregator exits 0 on linux"
assert_contains "$out" "mysql|MySQL|mysqld|databases|systemd|system|mysql" \
    "Case 3b: linux reuses the systemd mapping (no dedicated linux fn)"

# ─── Case 4: hermetic fixtures — skip _-prefixed, skip missing-meta, omit ────
#            services with no descriptor for the requested OS.
FIX="$SANDBOX/reg"
mkdir -p "$FIX"
cat >"$FIX/good.sh" <<'EOF'
# shellcheck shell=bash
svcdef_good_meta() { echo "Good|g|testtopic"; }
svcdef_good_wsl()  { echo "systemd|system|goodunit"; }
EOF
cat >"$FIX/_helper.sh" <<'EOF'
# shellcheck shell=bash
svcdef__helper_meta() { echo "Helper|h|nope"; }
EOF
cat >"$FIX/nometa.sh" <<'EOF'
# shellcheck shell=bash
svcdef_nometa_wsl() { echo "systemd|system|nometaunit"; }
EOF

out="$(resolve_in wsl "$FIX" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "Case 4a: aggregator exits 0 over a fixture dir"
assert_contains "$out" "good|Good|g|testtopic|systemd|system|goodunit" \
    "Case 4b: a well-formed fixture descriptor resolves"
assert_not_contains "$out" "_helper" "Case 4c: _-prefixed files are not treated as services"
assert_not_contains "$out" "nometa"  "Case 4d: a module missing svcdef_<id>_meta is skipped"

out_mac="$(resolve_in mac "$FIX" 2>/dev/null)"
assert_not_contains "$out_mac" "good|" "Case 4e: a service with no descriptor for the OS is omitted"

# ─── Case 5: the missing-meta skip warns on STDERR, never corrupting stdout ──
err="$(resolve_in wsl "$FIX" 2>&1 1>/dev/null)"
assert_contains "$err" "nometa" "Case 5: missing-meta module is reported on stderr"

# ─── T-002 ───────────────────────────────────────────────────────────────────
# Cross-platform drivers (systemd / brew / launchd) behind the uniform svc_*
# interface in driver.sh. We exercise command DISPATCH + the capability matrix
# OS-AGNOSTICALLY by shimming the platform binaries onto PATH and recording
# their argv — the same stub-the-environment discipline T-001 used for the OS.
# Real daemon behaviour is G-2's manual mac/crc check.

DRIVER="$REPO_ROOT/scripts/lib/services/driver.sh"
assert_file_exists "$DRIVER" "T-002: driver.sh (uniform svc_* interface) exists"

SHIM="$SANDBOX/bin"
SHIM_LOG="$SANDBOX/calls"
mkdir -p "$SHIM" "$SHIM_LOG"

# systemctl stub: log argv; optional targeted failure (STUB_SYSTEMCTL_FAIL is a
# substring of the argv that should fail); answer is-active/is-enabled from env.
cat >"$SHIM/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/systemctl.calls"
[[ -n "\${STUB_SYSTEMCTL_FAIL:-}" && "\$*" == *"\${STUB_SYSTEMCTL_FAIL}"* ]] && exit 1
case "\$*" in
    *list-unit-files*) printf '%s\n' "\${STUB_UNIT_FILES:-}"; exit 0 ;;
    *is-active*)  echo "\${STUB_ACTIVE:-active}";   [[ "\${STUB_ACTIVE:-active}" == active ]] ; exit \$? ;;
    *is-enabled*) echo "\${STUB_ENABLED:-enabled}"; [[ "\${STUB_ENABLED:-enabled}" == enabled ]] ; exit \$? ;;
esac
exit 0
EOF

# sudo stub: log the wrapped command, then exec it (so the inner shim still runs).
cat >"$SHIM/sudo" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/sudo.calls"
exec "\$@"
EOF

# brew stub: log argv; `services list` prints a canned table driven by env.
cat >"$SHIM/brew" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/brew.calls"
if [[ "\$1" == services && "\$2" == list ]]; then
    echo "Name Status User File"
    echo "mysql \${STUB_BREW_MYSQL:-none} me -"
    echo "redis \${STUB_BREW_REDIS:-none} me -"
fi
exit 0
EOF

# loginctl stub: log argv; show-user reports linger (default yes → no sudo path).
cat >"$SHIM/loginctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/loginctl.calls"
[[ "\$1" == show-user ]] && echo "Linger=\${STUB_LINGER:-yes}"
exit 0
EOF

# launchctl stub: log argv; `list <label>` returns a dict driven by env.
cat >"$SHIM/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/launchctl.calls"
if [[ "\$1" == list && -n "\${2:-}" ]]; then
    [[ "\${STUB_LAUNCHD_LOADED:-1}" == 1 ]] || exit 1
    echo '{'
    [[ "\${STUB_LAUNCHD_PID:-1}" == 1 ]] && echo '  "PID" = 4242;'
    echo '}'
fi
exit 0
EOF
chmod +x "$SHIM"/systemctl "$SHIM"/sudo "$SHIM"/brew "$SHIM"/loginctl "$SHIM"/launchctl

# run_drv "<call>" — source the driver with the shim FIRST on PATH and run one
# call (logs reset each time so each case is hermetic). Returns the call's rc.
run_drv() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    PATH="$SHIM:$PATH" NO_COLOR=1 bash -c "source '$DRIVER'; $1"
}
calls() { cat "$SHIM_LOG/$1.calls" 2>/dev/null; }

# ─── Case 6: systemd SYSTEM scope — reads need no root, mutations use sudo ────
out="$(run_drv "svc_status systemd system mysql")"
sd_calls="$(calls systemctl)"; sudo_calls="$(calls sudo)"
assert_contains "$out" "active=on"      "Case 6a: systemd status maps is-active → active=on"
assert_contains "$out" "enabled=on"     "Case 6b: systemd status maps is-enabled → enabled=on"
assert_contains "$out" "orthogonal=yes" "Case 6c: systemd is reported orthogonal"
assert_contains "$sd_calls" "is-active mysql" "Case 6d: status reads via systemctl is-active"
assert_not_contains "$sudo_calls" "systemctl"  "Case 6e: a systemd STATUS read never uses sudo"

run_drv "svc_start systemd system mysql" >/dev/null
assert_contains "$(calls sudo)" "systemctl start mysql" "Case 6f: systemd system START is wrapped in sudo"
assert_contains "$(calls systemctl)" "start mysql"      "Case 6g: ...and reaches systemctl start"

# ─── Case 7: systemd USER scope (mailpit) — systemctl --user, never sudo ─────
run_drv "svc_status systemd user mailpit" >/dev/null
assert_contains "$(calls systemctl)" "--user is-active mailpit" "Case 7a: user-scope status reads via systemctl --user"

run_drv "svc_start systemd user mailpit" >/dev/null
assert_contains "$(calls systemctl)" "--user start mailpit" "Case 7b: user-scope start uses systemctl --user"
assert_not_contains "$(calls sudo)" "systemctl"             "Case 7c: user-scope start never sudo-runs systemctl"

run_drv "svc_enable systemd user mailpit" >/dev/null
assert_contains "$(calls systemctl)" "--user enable mailpit" "Case 7d: user-scope enable uses systemctl --user"
assert_not_contains "$(calls sudo)" "systemctl"              "Case 7e: user-scope enable never sudo-runs systemctl"

# ─── Case 8: brew NON-ORTHOGONAL verb→command mapping (codex F-001) ──────────
run_drv "svc_start brew '' mysql" >/dev/null
assert_contains "$(calls brew)"     "services run mysql"  "Case 8a: brew START → brew services run (active only)"
assert_not_contains "$(calls brew)" "services start"      "Case 8b: brew start does NOT register login autostart"

run_drv "svc_enable brew '' mysql" >/dev/null
assert_contains "$(calls brew)" "services start mysql" "Case 8c: brew ENABLE → brew services start (runs + registers)"

run_drv "svc_stop brew '' mysql" >/dev/null
assert_contains "$(calls brew)" "services stop mysql" "Case 8d: brew STOP → brew services stop"

out="$(run_drv "export STUB_BREW_MYSQL=started; svc_status brew '' mysql")"
assert_contains "$out" "orthogonal=no" "Case 8e: brew status labels the backend non-orthogonal"
assert_contains "$out" "active=on"     "Case 8f: brew 'started' → active=on"
out="$(run_drv "export STUB_BREW_MYSQL=none; svc_status brew '' mysql")"
assert_contains "$out" "active=off"    "Case 8g: brew 'none' → active=off"

# ─── Case 9: the capability matrix as queryable data ─────────────────────────
ASSERT_MSG="Case 9a: svc_orthogonal systemd → true"  assert_true  "run_drv 'svc_orthogonal systemd' >/dev/null"
ASSERT_MSG="Case 9b: svc_orthogonal launchd → true"  assert_true  "run_drv 'svc_orthogonal launchd' >/dev/null"
ASSERT_MSG="Case 9c: svc_orthogonal brew → false"    assert_false "run_drv 'svc_orthogonal brew'    >/dev/null"
assert_eq "$(run_drv 'svc_collateral brew enable')"    "active"  "Case 9d: brew ENABLE collaterally flips active"
assert_eq "$(run_drv 'svc_collateral brew stop')"      "enabled" "Case 9e: brew STOP collaterally flips enabled"
assert_eq "$(run_drv 'svc_collateral brew start')"     ""        "Case 9f: brew START is clean (no collateral)"
assert_eq "$(run_drv 'svc_collateral systemd enable')" ""        "Case 9g: systemd enable has no collateral"

# ─── Case 10: an unknown backend kind is rejected, never silently dispatched ─
out="$(run_drv "svc_start bogus system x" 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 10a: dispatch to an unknown backend kind fails"
assert_contains "$out" "unknown backend kind" "Case 10b: ...with a clear message"

# ─── Case 11: launchd backend — orthogonal + gui-domain dispatch ─────────────
out="$(run_drv "export STUB_LAUNCHD_PID=1; svc_status launchd '' com.example.daemon")"
assert_contains "$out" "active=on"      "Case 11a: launchd status active when a PID is present"
assert_contains "$out" "orthogonal=yes" "Case 11b: launchd is reported orthogonal"
run_drv "svc_enable launchd '' com.example.daemon" >/dev/null
assert_contains "$(calls launchctl)" "enable gui/" "Case 11c: launchd enable runs launchctl enable in the gui domain"

# ─── T-003 ───────────────────────────────────────────────────────────────────
# The runner scripts/runners/services.sh: non-interactive verbs that resolve the
# registry, dispatch the driver, and report per-service + aggregate exit. Run it
# under MESH_SERVICES_OS=wsl with the same PATH-shim so systemd state/mutations
# are stubbed. bin/mesh wiring is asserted structurally (the live dispatch is
# G-2's manual check).

RUNNER="$REPO_ROOT/scripts/runners/services.sh"
assert_file_exists "$RUNNER" "T-003: runner scripts/runners/services.sh exists"

# run_svc <args...> — run the runner (wsl OS) with the shim on PATH; reset logs.
run_svc() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    PATH="$SHIM:$PATH" MESH_SERVICES_OS=wsl NO_COLOR=1 bash "$RUNNER" "$@"
}

# ─── Case 12: `list` (human) — badges + owner + header ───────────────────────
out="$(run_svc list)"
assert_contains "$out" "SERVICE"   "Case 12a: list prints a header row"
assert_contains "$out" "mysql"     "Case 12b: list includes the mysql service"
assert_contains "$out" "running"   "Case 12c: list shows the active badge (is-active→running)"
assert_contains "$out" "on-boot"   "Case 12d: list shows the enabled badge (is-enabled→on-boot)"
assert_contains "$out" "databases" "Case 12e: list shows the owning topic"

# ─── Case 13: `list --porcelain` — machine row the TUI (T-004) consumes ──────
out="$(run_svc list --porcelain)"
assert_contains "$out" "mysql|MySQL|mysqld|databases|systemd|system|mysql|on|on" \
    "Case 13: --porcelain emits id|…|target|active|enabled"

# ─── Case 14: `status <name>` — two bits + backend ───────────────────────────
out="$(run_svc status mysql)"
assert_contains "$out" "MySQL"          "Case 14a: status names the service"
assert_contains "$out" "systemd/system" "Case 14b: status shows the backend + scope"
assert_contains "$out" "running"        "Case 14c: status shows active"
assert_contains "$out" "on-boot"        "Case 14d: status shows enabled"

# ─── Case 15: fuzzy/substring match on id ────────────────────────────────────
out="$(run_svc status my)"
assert_contains "$out" "MySQL (mysql)" "Case 15: a substring of the id resolves the service"

# ─── Case 16: an ambiguous name is refused, not guessed ──────────────────────
out="$(run_svc status s 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 16a: an ambiguous name exits non-zero"
assert_contains "$out" "ambiguous" "Case 16b: ...and names the candidates"

# ─── Case 17: an unknown name is a clear error ───────────────────────────────
out="$(run_svc status nope 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 17a: an unknown name exits non-zero"
assert_contains "$out" "no service matches" "Case 17b: ...with a clear no-match message"

# ─── Case 18: multi-service verb — both acted, dispatched through the driver ─
out="$(run_svc stop mysql redis 2>&1)"; rc=$?
sudo_calls="$(calls sudo)"
assert_eq "$rc" "0" "Case 18a: 'stop mysql redis' exits 0 when both succeed"
assert_contains "$sudo_calls" "systemctl stop mysql"        "Case 18b: mysql stopped via sudo systemctl"
assert_contains "$sudo_calls" "systemctl stop redis-server" "Case 18c: redis stopped via its apt unit name redis-server"

# ─── Case 19: partial failure (bad name) → aggregate non-zero ────────────────
out="$(run_svc stop mysql bogus 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 19a: a bad name in a batch makes the verb exit non-zero"
assert_contains "$out" "MySQL: stop"                "Case 19b: ...but the resolvable service is still acted on"
assert_contains "$out" "no service matches 'bogus'" "Case 19c: ...and the bad name is reported"

# ─── Case 20: driver failure → aggregate non-zero ────────────────────────────
export STUB_SYSTEMCTL_FAIL='stop mysql'
out="$(run_svc stop mysql redis 2>&1)"; rc=$?
unset STUB_SYSTEMCTL_FAIL
assert_ne "$rc" 0 "Case 20a: a failing driver mutation makes the verb exit non-zero"
assert_contains "$out" "MySQL: stop failed" "Case 20b: the failing service is reported as failed"

# ─── Case 21: bin/mesh wiring (structural; live dispatch is G-2) ─────────────
MESH="$REPO_ROOT/bin/mesh"
ASSERT_MSG="Case 21a: bin/mesh defines sub_services()" assert_true "grep -q 'sub_services()' '$MESH'"
ASSERT_MSG="Case 21b: bin/mesh dispatches the 'services' subcommand" assert_true "grep -qE '^[[:space:]]*services\\)' '$MESH'"

# ─── T-004 (shell side) ──────────────────────────────────────────────────────
# The interactive no-arg flow lives in the blink-tui menu (TS, covered by the
# menu vitest). Here we only assert the runner's NON-interactive contract: the
# no-arg invocation must never hang in CI/scripts, and -h still prints usage.
export NON_INTERACTIVE=1
out="$(run_svc 2>&1)"; rc=$?
unset NON_INTERACTIVE
assert_eq "$rc" "0" "Case 22a: no-arg services in a non-interactive context exits 0 (never hangs)"
assert_contains "$out" "Usage:"        "Case 22b: ...and prints usage instead of launching the TUI"
assert_contains "$out" "interactive"   "Case 22c: usage documents the interactive no-arg flow"

out="$(run_svc -h 2>&1)"; rc=$?
assert_eq "$rc" "0" "Case 22d: -h prints usage and exits 0"
assert_contains "$out" "mesh services list" "Case 22e: usage lists the verbs"

# ─── T-005 ───────────────────────────────────────────────────────────────────
# Dynamic php-fpm enumeration + `--all` discovery (read-only) + the
# `mesh run --all services` fan-out allowlist. Enumeration globs a fixture
# /etc/php via MESH_PHP_FPM_DIR (hermetic, mirrors MESH_CLEAN_OS); discovery is
# driven by the systemctl `list-unit-files` stub (STUB_UNIT_FILES); the fan-out
# allowlist is exercised behaviourally on bin/mesh — it is checked BEFORE host
# selection, and --dry-run guarantees no ssh is attempted.

# php fixture: four installed versions under <root>/<ver>/fpm (the WSL layout).
PHPDIR="$SANDBOX/etcphp"
mkdir -p "$PHPDIR/8.2/fpm" "$PHPDIR/8.3/fpm" "$PHPDIR/8.4/fpm" "$PHPDIR/8.5/fpm"

# ─── Case 23: php-fpm enumerates one row per installed version (WSL) ──────────
out="$(MESH_PHP_FPM_DIR="$PHPDIR" MESH_SERVICES_OS=wsl NO_COLOR=1 bash "$AGG" 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 23a: aggregator exits 0 with php enumeration"
assert_contains "$out" "php-fpm@8.2|PHP-FPM 8.2|php,fpm|languages|systemd|system|php8.2-fpm" \
    "Case 23b: php 8.2 enumerates to its own systemd unit row (php8.2-fpm)"
assert_contains "$out" "php-fpm@8.5|PHP-FPM 8.5|php,fpm|languages|systemd|system|php8.5-fpm" \
    "Case 23c: php 8.5 enumerates to php8.5-fpm"
n_php="$(printf '%s\n' "$out" | grep -c '^php-fpm@')"
assert_eq "$n_php" 4 "Case 23d: exactly one row per installed php version (4)"
assert_not_contains "$out" "php-fpm|" "Case 23e: the static single php-fpm row is replaced by the enumerated rows"

# ─── Case 24: no installed versions → the static fallback row ─────────────────
EMPTYPHP="$SANDBOX/emptyphp"; mkdir -p "$EMPTYPHP"
out="$(MESH_PHP_FPM_DIR="$EMPTYPHP" MESH_SERVICES_OS=wsl NO_COLOR=1 bash "$AGG" 2>&1)"
assert_contains "$out" "php-fpm|PHP-FPM|php,fpm|languages|systemd|system|php-fpm" \
    "Case 24: empty enumeration falls back to the static php-fpm row"

# run_svc_php <args...> — runner under wsl with the shim AND the php fixture dir.
run_svc_php() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    PATH="$SHIM:$PATH" MESH_PHP_FPM_DIR="$PHPDIR" MESH_SERVICES_OS=wsl NO_COLOR=1 bash "$RUNNER" "$@"
}

# ─── Case 25: stopping one php version leaves the others untouched ────────────
out="$(run_svc_php stop php-fpm@8.2 2>&1)"; rc=$?
sudo_calls="$(calls sudo)"
assert_eq "$rc" 0 "Case 25a: 'stop php-fpm@8.2' resolves the exact version and exits 0"
assert_contains "$sudo_calls" "systemctl stop php8.2-fpm" "Case 25b: it stops only the 8.2 unit"
assert_not_contains "$sudo_calls" "php8.3-fpm" "Case 25c: ...and leaves 8.3 untouched"
assert_not_contains "$sudo_calls" "php8.5-fpm" "Case 25d: ...and leaves 8.5 untouched"

# ─── Case 26: `list --all` surfaces discovered (non-curated) units, deduped ───
export STUB_UNIT_FILES='mysql.service enabled enabled
cups.service disabled disabled
ssh.service enabled enabled'
out="$(run_svc list --all --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 26a: list --all --porcelain exits 0"
assert_contains "$out" "cups|cups||discovered|systemd|system|cups" \
    "Case 26b: a non-curated systemd unit is discovered read-only and marked 'discovered'"
assert_contains "$out" "ssh|ssh||discovered|systemd|system|ssh" \
    "Case 26c: ...every discovered unit, not just one"
mysql_lines="$(printf '%s\n' "$out" | grep -c '^mysql|')"
assert_eq "$mysql_lines" 1 "Case 26d: a curated unit re-seen by discovery is not duplicated (dedupe)"
unset STUB_UNIT_FILES

# ─── Case 27: plain `list` (no --all) shows ONLY the curated registry ─────────
export STUB_UNIT_FILES='cups.service disabled disabled'
out="$(run_svc list --porcelain 2>&1)"
unset STUB_UNIT_FILES
assert_not_contains "$out" "cups" "Case 27: discovery is opt-in — plain list omits non-curated units"

# ─── Case 28: a mutating verb on a discovered (non-curated) unit is refused ───
export STUB_UNIT_FILES='cups.service enabled enabled'
out="$(run_svc stop cups 2>&1)"; rc=$?
unset STUB_UNIT_FILES
assert_ne "$rc" 0 "Case 28a: stopping a discovered, non-curated unit exits non-zero"
assert_contains "$out" "only curated services are mutable" \
    "Case 28b: ...with a clear curated-only refusal (not a bare no-match)"

# ─── Case 29: `mesh run --all services` fan-out allowlist (behavioural) ───────
# The allowlist is checked before host selection; --dry-run guarantees no ssh.
out="$(bash "$MESH" run --dry-run --all services bogus 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 29a: an out-of-scope services subverb is rejected by the fan-out allowlist"
assert_contains "$out" "can only fan out" "Case 29b: ...with a clear allowlist message"
out="$(bash "$MESH" run --dry-run --all services 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 29c: fanning out the interactive no-subverb form is rejected"
out="$(bash "$MESH" run --dry-run --all services status mysql 2>&1)"; rc=$?
assert_not_contains "$out" "can only fan out"        "Case 29d: 'services status' clears the allowlist"
assert_not_contains "$out" "unsupported mesh subcommand" "Case 29e: 'services' is a supported fan-out subcommand"

# ─── Case 30: services is forced non-interactive in the fan-out (structural) ──
ASSERT_MSG="Case 30: _run_force_noninteractive covers services (a stray no-arg never hangs a host)" \
    assert_true "grep -A1 '_run_force_noninteractive()' '$MESH' | grep -q services"

# ─── T-006 ───────────────────────────────────────────────────────────────────
# Decouple install from auto-enable + per-host services.default reconcile. The
# opt-out set grows to 5 daemons (mysql, redis, php-fpm, postgres, docker — all
# opt-out on wsl). Topic installers apply boot-state via the shared services lib
# (services_reconcile_one) instead of an inline `systemctl enable --now`; the
# new `mesh services reconcile` verb flips the enabled bit ONLY toward the host's
# services.default.<alias> and is idempotent. Reconcile logic runs over a
# HERMETIC fixture registry + a fixture services.default (set fully controlled,
# mirrors Case 4); the new real descriptors (postgres/docker) are asserted
# against the shipped registry.

# optq <os> <regdir> <fn> [args…] — source the aggregator in a subshell and run
# one registry function (so services_optout/_ids are callable in isolation).
optq() {
    local os="$1" reg="$2"; shift 2
    # Dummy $0 (not $AGG) so the aggregator's `BASH_SOURCE==$0` run-direct guard
    # does NOT fire on `source` — we want only the called function's output.
    MESH_SERVICES_OS="$os" MESH_SERVICES_REGISTRY_DIR="$reg" NO_COLOR=1 \
        bash -c 'source "$1"; shift; "$@"' _ "$AGG" "$@"
}

# ─── Case 31: the new real descriptors resolve + are opt-out on wsl ───────────
out="$(resolve wsl 2>&1)"
assert_contains "$out" "docker|Docker|dockerd,docker-ce|containers|systemd|system|docker" \
    "Case 31a: docker resolves to the wsl systemd unit"
assert_not_contains "$(resolve mac 2>/dev/null)" "docker|" \
    "Case 31b: docker has no mac mapping (Docker Desktop ≠ brew/launchd svc) → omitted on mac"
out="$(MESH_PG_DIR="$SANDBOX/nopg" MESH_SERVICES_OS=wsl NO_COLOR=1 bash "$AGG" 2>&1)"
assert_contains "$out" "postgres|PostgreSQL|psql,pg,postgresql|databases|systemd|system|postgresql" \
    "Case 31c: postgres falls back to its static row with no clusters installed"

# ─── Case 32: postgres enumerates one row per installed cluster (mirrors php) ──
PGDIR="$SANDBOX/etcpg"
mkdir -p "$PGDIR/16/main" "$PGDIR/15/main"
out="$(MESH_PG_DIR="$PGDIR" MESH_SERVICES_OS=wsl NO_COLOR=1 bash "$AGG" 2>&1)"
assert_contains "$out" "postgres@16-main|PostgreSQL 16/main|psql,pg,postgresql|databases|systemd|system|postgresql@16-main" \
    "Case 32a: postgres 16/main enumerates to its versioned cluster unit"
assert_contains "$out" "postgres@15-main|PostgreSQL 15/main|psql,pg,postgresql|databases|systemd|system|postgresql@15-main" \
    "Case 32b: postgres 15/main enumerates too"
n_pg="$(printf '%s\n' "$out" | grep -c '^postgres@')"
assert_eq "$n_pg" 2 "Case 32c: exactly one row per installed cluster (2)"

# Hermetic opt-out registry: alpha+beta are opt-out on wsl, gamma is NOT.
OREG="$SANDBOX/optreg"
mkdir -p "$OREG"
cat >"$OREG/alpha.sh" <<'EOF'
svcdef_alpha_meta()   { echo "Alpha|a|testtopic"; }
svcdef_alpha_wsl()    { echo "systemd|system|alphaunit"; }
svcdef_alpha_optout() { echo "wsl"; }
EOF
cat >"$OREG/beta.sh" <<'EOF'
svcdef_beta_meta()   { echo "Beta|b|testtopic"; }
svcdef_beta_wsl()    { echo "systemd|system|betaunit"; }
svcdef_beta_optout() { echo "wsl"; }
EOF
cat >"$OREG/gamma.sh" <<'EOF'
svcdef_gamma_meta() { echo "Gamma|g|testtopic"; }
svcdef_gamma_wsl()  { echo "systemd|system|gammaunit"; }
EOF

# ─── Case 33: services_optout / services_optout_ids ──────────────────────────
ASSERT_MSG="Case 33a: services_optout(alpha,wsl) is true" \
    assert_true "optq wsl '$OREG' services_optout alpha wsl"
ASSERT_MSG="Case 33b: services_optout(alpha,mac) is false (only the wsl token)" \
    assert_false "optq wsl '$OREG' services_optout alpha mac"
ASSERT_MSG="Case 33c: services_optout(gamma,wsl) is false (no opt-out hook)" \
    assert_false "optq wsl '$OREG' services_optout gamma wsl"
ids="$(optq wsl "$OREG" services_optout_ids wsl)"
assert_contains "$ids" "alpha" "Case 33d: optout_ids lists the opt-out alpha"
assert_contains "$ids" "beta"  "Case 33e: optout_ids lists the opt-out beta"
assert_not_contains "$ids" "gamma" "Case 33f: optout_ids omits the non-opt-out gamma"
# Real registry: enumerated instances inherit their descriptor's opt-out.
ids_real="$(MESH_PHP_FPM_DIR="$PHPDIR" MESH_PG_DIR="$SANDBOX/nopg" MESH_SERVICES_OS=wsl \
    bash -c 'source "$1"; shift; "$@"' _ "$AGG" services_optout_ids wsl)"
assert_contains "$ids_real" "php-fpm@8.2" "Case 33g: an enumerated php-fpm instance inherits its descriptor's opt-out"
assert_contains "$ids_real" "postgres" "Case 33h: postgres is in the real opt-out set"
assert_contains "$ids_real" "docker"   "Case 33i: docker is in the real opt-out set"

# run_svc_recon <default-contents> [args…] — runner `reconcile` over the hermetic
# opt-out registry + a fixture services.default. STUB_ENABLED drives the current
# boot bit the systemctl shim reports; mutations land in the sudo call-log.
run_svc_recon() {
    local def="$1"; shift
    local deffile="$SANDBOX/services.default.test"
    printf '%s' "$def" >"$deffile"
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    PATH="$SHIM:$PATH" MESH_SERVICES_OS=wsl MESH_SERVICES_REGISTRY_DIR="$OREG" \
        MESH_SERVICES_DEFAULT="$deffile" NO_COLOR=1 bash "$RUNNER" reconcile "$@"
}

# ─── Case 34: reconcile DISABLES opt-out daemons absent from services.default ──
export STUB_ENABLED=enabled            # every unit currently enabled-at-boot
out="$(run_svc_recon "" 2>&1)"; rc=$?
sudo_calls="$(calls sudo)"
assert_eq "$rc" 0 "Case 34a: reconcile with an empty services.default exits 0"
assert_contains "$sudo_calls" "systemctl disable alphaunit" "Case 34b: an opt-out, not-opted-in daemon is disabled at boot"
assert_contains "$sudo_calls" "systemctl disable betaunit"  "Case 34c: ...every one of them"
assert_not_contains "$sudo_calls" "enable" "Case 34d: nothing is enabled when services.default is empty"
unset STUB_ENABLED

# ─── Case 35: reconcile ENABLES an opted-in daemon, leaves the rest off ───────
export STUB_ENABLED=disabled           # every unit currently disabled-at-boot
out="$(run_svc_recon $'alpha\n' 2>&1)"; rc=$?
sudo_calls="$(calls sudo)"
assert_eq "$rc" 0 "Case 35a: reconcile with services.default=alpha exits 0"
assert_contains "$sudo_calls" "systemctl enable alphaunit" "Case 35b: the opted-in daemon is enabled at boot"
assert_not_contains "$sudo_calls" "enable betaunit" "Case 35c: a non-opted-in daemon is not enabled"
unset STUB_ENABLED

# ─── Case 36: reconcile is IDEMPOTENT — no mutation when state already matches ─
# desired==current for every daemon (all enabled, all opted-in) ⇒ a second run is
# a no-op. With a static is-enabled stub, "already converged" IS the second run.
export STUB_ENABLED=enabled
out="$(run_svc_recon $'alpha\nbeta\n' 2>&1)"; rc=$?
sudo_calls="$(calls sudo)"
assert_eq "$rc" 0 "Case 36a: reconcile of an already-converged host exits 0"
assert_not_contains "$sudo_calls" "enable"  "Case 36b: ...issues no enable"
assert_not_contains "$sudo_calls" "disable" "Case 36c: ...and no disable (idempotent)"
unset STUB_ENABLED

# ─── Case 37: reconcile touches ONLY the enabled bit — never start/stop ───────
export STUB_ENABLED=enabled
out="$(run_svc_recon "" 2>&1)"
all_calls="$(calls systemctl)$(calls sudo)"
assert_not_contains "$all_calls" "systemctl start" "Case 37a: reconcile never starts a unit"
assert_not_contains "$all_calls" "systemctl stop"  "Case 37b: reconcile never stops a running unit (G-3: boot bit only)"
unset STUB_ENABLED

# ─── Case 38: topic installers decoupled from inline auto-enable (structural) ──
MYSQL_TOPIC="$REPO_ROOT/topics/databases/wsl/mysql.sh"
DOCKER_TOPIC="$REPO_ROOT/topics/containers/post-setup-wsl.sh"
PG_TOPIC="$REPO_ROOT/topics/databases/scripts/install-postgres.sh"
ASSERT_MSG="Case 38a: mysql.sh no longer force-enables at boot (no 'enable --now mysql')" \
    assert_true "! grep -qF 'enable --now mysql' '$MYSQL_TOPIC'"
ASSERT_MSG="Case 38b: mysql.sh applies boot-state via the shared services lib (_apply_boot_state mysql)" \
    assert_true "grep -qF '_apply_boot_state mysql' '$MYSQL_TOPIC' && grep -qF 'reconcile.sh' '$MYSQL_TOPIC'"
ASSERT_MSG="Case 38c: post-setup-wsl.sh no longer 'enable --now docker'" \
    assert_true "! grep -qF 'enable --now docker' '$DOCKER_TOPIC'"
ASSERT_MSG="Case 38d: post-setup-wsl.sh applies docker boot-state via the services lib (_apply_boot_state docker)" \
    assert_true "grep -qF '_apply_boot_state docker' '$DOCKER_TOPIC' && grep -qF 'reconcile.sh' '$DOCKER_TOPIC'"
ASSERT_MSG="Case 38e: install-postgres.sh no longer unconditionally enables the cluster unit" \
    assert_true "! grep -qF 'systemctl enable \"\$unit\"' '$PG_TOPIC'"
ASSERT_MSG="Case 38f: install-postgres.sh applies postgres boot-state via the services lib (_apply_boot_state postgres)" \
    assert_true "grep -qF '_apply_boot_state postgres' '$PG_TOPIC' && grep -qF 'reconcile.sh' '$PG_TOPIC'"

# ─── Case 39: `mesh update` reconciles boot-state toward services.default ──────
AUTOUPD="$REPO_ROOT/scripts/runners/auto-update.sh"
ASSERT_MSG="Case 39a: auto-update.sh gates a reconcile on a services.default change" \
    assert_true "grep -qF '_services_default_changed' '$AUTOUPD'"
ASSERT_MSG="Case 39b: auto-update.sh runs 'mesh services reconcile'" \
    assert_true "grep -qF 'services reconcile' '$AUTOUPD'"

# ─── Case 40: the runner documents + dispatches the reconcile verb ────────────
out="$(run_svc -h 2>&1)"
assert_contains "$out" "reconcile" "Case 40a: usage documents the reconcile verb"
out="$(run_svc reconcile zzz-no-such-service 2>&1)"; rc=$?
assert_ne "$rc" 0 "Case 40b: reconcile of an unknown name exits non-zero (never a crash)"

summary
