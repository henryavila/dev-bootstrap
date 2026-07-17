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
REGISTRY_HOME="$SANDBOX/registry-home"
mkdir -p "$REGISTRY_HOME"

# Resolve the registry for a stubbed OS against the REAL shipped descriptors.
resolve() { HOME="$REGISTRY_HOME" USER=mesh-test MESH_SERVICES_OS="$1" NO_COLOR=1 bash "$AGG"; }
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
[[ -n "\${STUB_SYSTEMCTL_FAIL:-}" && "\$*" == *"\${STUB_SYSTEMCTL_FAIL}"* ]] \
    && exit "\${STUB_SYSTEMCTL_FAIL_RC:-1}"
case "\$*" in
    *list-unit-files*) printf '%s\n' "\${STUB_UNIT_FILES-}"; exit 0 ;;
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
if [[ "\$1" == list && "\${2:-}" == --formula ]]; then
    formulas="\${STUB_BREW_INSTALLED_FORMULAS-mysql redis php@8.4 postgresql@17}"
    if [[ "\${3:-}" == --versions ]]; then
        target="\${4:-}"
        for formula in \$formulas; do
            [[ "\$formula" == "\$target" ]] && { printf '%s 1.0\n' "\$formula"; exit 0; }
        done
        exit 1
    fi
    for formula in \$formulas; do
        printf '%s\n' "\$formula"
    done
    exit 0
fi
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

# launchctl stub: log argv. The default mode is the original stateless fixture;
# STUB_LAUNCHD_STATE_DIR enables a small state machine so launchd mutations and
# their post-conditions can be tested without touching the host's real domain.
cat >"$SHIM/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/launchctl.calls"
label="\${STUB_LAUNCHD_LABEL:-com.example.daemon}"
state="\${STUB_LAUNCHD_STATE_DIR:-}"

if [[ -n "\$state" ]]; then
    case "\${1:-}" in
        print)
            if [[ "\${2:-}" == */"\$label" ]]; then
                print_count=0
                [[ -f "\$state/print-service-count" ]] \
                    && print_count="\$(awk 'NR == 1 { print; exit }' "\$state/print-service-count")"
                print_count="\$((print_count + 1))"
                printf '%s\n' "\$print_count" >"\$state/print-service-count"
                [[ "\${STUB_LAUNCHD_FAIL_PRINT_SERVICE_AT:-}" == "\$print_count" ]] && exit 64
                [[ "\${STUB_LAUNCHD_FAIL:-}" == print-service ]] && exit 64
                [[ -f "\$state/loaded" ]] || exit 113
                echo '{'
                if [[ -f "\$state/pid" ]]; then
                    pid_value="\$(awk 'NR == 1 { print; exit }' "\$state/pid")"
                    printf '  pid = %s\n' "\${pid_value:-4242}"
                fi
                echo '}'
            else
                [[ "\${STUB_LAUNCHD_FAIL:-}" == print-domain ]] && exit 1
                echo "\${2:-gui/domain} = { }"
            fi
            exit 0
            ;;
        list)
            [[ -f "\$state/loaded" ]] || exit 1
            echo '{'
            [[ -f "\$state/pid" ]] && echo '  "PID" = 4242;'
            echo '}'
            exit 0
            ;;
        print-disabled)
            [[ "\${STUB_LAUNCHD_FAIL:-}" == print-disabled ]] && exit 1
            [[ "\${STUB_LAUNCHD_DISABLED_FORMAT:-}" == empty ]] && exit 0
            echo 'disabled services = {'
            case "\${STUB_LAUNCHD_DISABLED_FORMAT:-words}" in
                malformed) printf '    "%s" =>\n' "\$label" ;;
                absent)    printf '    "%s.decoy" => disabled\n' "\$label" ;;
                unquoted)  printf '    %s => disabled\n' "\$label" ;;
                boolean)
                    if [[ -f "\$state/disabled" ]]; then
                        printf '    "%s" => true\n' "\$label"
                    else
                        printf '    "%s" => false\n' "\$label"
                    fi
                    ;;
                *)
                    if [[ -f "\$state/disabled" ]]; then
                        printf '    "%s" => disabled\n' "\$label"
                    else
                        printf '    "%s" => enabled\n' "\$label"
                    fi
                    ;;
            esac
            echo '}'
            exit 0
            ;;
        enable)
            [[ "\${STUB_LAUNCHD_FAIL:-}" == enable ]] && exit 1
            if [[ "\${STUB_LAUNCHD_FAIL_ONCE:-}" == enable \
                && ! -f "\$state/failed-enable-once" ]]; then
                : >"\$state/failed-enable-once"
                exit 1
            fi
            [[ "\${STUB_LAUNCHD_NO_EFFECT:-}" == enable ]] || rm -f "\$state/disabled"
            exit 0
            ;;
        disable)
            [[ "\${STUB_LAUNCHD_FAIL:-}" == disable ]] && exit 1
            if [[ "\${STUB_LAUNCHD_FAIL_ONCE:-}" == disable \
                && ! -f "\$state/failed-disable-once" ]]; then
                : >"\$state/failed-disable-once"
                exit 1
            fi
            [[ "\${STUB_LAUNCHD_NO_EFFECT:-}" == disable ]] || : >"\$state/disabled"
            exit 0
            ;;
        bootout)
            [[ "\${STUB_LAUNCHD_FAIL:-}" == bootout ]] && exit 1
            if [[ "\${STUB_LAUNCHD_NO_EFFECT:-}" != bootout ]]; then
                rm -f "\$state/loaded"
                [[ "\${2:-}" == --wait ]] && rm -f "\$state/pid"
            fi
            exit 0
            ;;
        bootstrap)
            [[ "\${STUB_LAUNCHD_FAIL:-}" == bootstrap ]] && exit 1
            [[ -f "\$state/disabled" ]] && exit 3
            if [[ "\${STUB_LAUNCHD_SIGNAL_ON:-}" == bootstrap ]]; then
                kill -s "\${STUB_LAUNCHD_SIGNAL:-INT}" "\${STUB_LAUNCHD_SIGNAL_PID:?}"
                sleep 0.05
            fi
            if [[ "\${STUB_LAUNCHD_SIGNAL_RESULT:-}" == fail ]]; then
                : >"\$state/loaded"
                printf '4242\n' >"\$state/pid"
                exit 5
            fi
            if [[ "\${STUB_LAUNCHD_RACE:-}" == bootstrap ]]; then
                : >"\$state/loaded"
                printf '4242\n' >"\$state/pid"
                exit 5
            fi
            if [[ "\${STUB_LAUNCHD_NO_EFFECT:-}" != bootstrap ]]; then
                : >"\$state/loaded"
            fi
            exit 0
            ;;
        kickstart)
            [[ "\${STUB_LAUNCHD_FAIL:-}" == kickstart ]] && exit 1
            [[ -f "\$state/loaded" ]] || exit 3
            if [[ "\${STUB_LAUNCHD_NO_EFFECT:-}" != kickstart ]]; then
                if [[ -f "\$state/pid" ]]; then
                    pid_value="\$(awk 'NR == 1 { print; exit }' "\$state/pid")"
                    pid_value="\${pid_value:-4242}"
                    printf '%s\n' "\$((pid_value + 1))" >"\$state/pid"
                else
                    printf '4242\n' >"\$state/pid"
                fi
            fi
            exit 0
            ;;
        stop)
            # A loaded KeepAlive job is immediately relaunched: legacy stop does
            # not unload it and therefore leaves both state files present.
            exit 0
            ;;
    esac
fi

if [[ "\${1:-}" == print ]]; then
    if [[ "\${2:-}" == */"\$label" ]]; then
        [[ "\${STUB_LAUNCHD_LOADED:-1}" == 1 ]] || exit 113
        echo '{'
        [[ "\${STUB_LAUNCHD_PID:-1}" == 1 ]] && echo '  pid = 4242'
        echo '}'
    else
        echo "\${2:-gui/domain} = { }"
    fi
elif [[ "\${1:-}" == list && -n "\${2:-}" ]]; then
    [[ "\${STUB_LAUNCHD_LOADED:-1}" == 1 ]] || exit 1
    echo '{'
    [[ "\${STUB_LAUNCHD_PID:-1}" == 1 ]] && echo '  "PID" = 4242;'
    echo '}'
elif [[ "\${1:-}" == print-disabled ]]; then
    echo 'disabled services = {'
    if [[ "\${STUB_LAUNCHD_DISABLED:-0}" == 1 ]]; then
        printf '    "%s" => disabled\n' "\$label"
    else
        printf '    "%s" => enabled\n' "\$label"
    fi
    echo '}'
fi
exit 0
EOF

# shlock stub: model the macOS utility's live-owner refusal and atomic stale-PID
# recovery so launchd locking remains testable on non-macOS CI hosts.
cat >"$SHIM/shlock" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$SHIM_LOG/shlock.calls"
pid=""
lock=""
while (( \$# )); do
    case "\$1" in
        -p) pid="\${2:-}"; shift 2 ;;
        -f) lock="\${2:-}"; shift 2 ;;
        *)  exit 64 ;;
    esac
done
[[ "\$pid" =~ ^[0-9]+$ && -n "\$lock" ]] || exit 64
if [[ -f "\$lock" ]]; then
    owner="\$(awk 'NR == 1 { print; exit }' "\$lock")"
    if [[ "\$owner" =~ ^[0-9]+$ ]] && kill -0 "\$owner" 2>/dev/null; then
        exit 1
    fi
    if [[ -n "\${STUB_SHLOCK_STALE_DELAY_MARKER:-}" \
        && ! -e "\$STUB_SHLOCK_STALE_DELAY_MARKER" ]]; then
        : >"\$STUB_SHLOCK_STALE_DELAY_MARKER"
        exit 1
    fi
fi
rm -f "\$lock"
claim="\${lock}.claim.\${pid}.\${RANDOM}"
printf '%s\n' "\$pid" >"\$claim" || exit 1
ln "\$claim" "\$lock" 2>/dev/null
rc=\$?
rm -f "\$claim"
exit "\$rc"
EOF
chmod +x "$SHIM"/systemctl "$SHIM"/sudo "$SHIM"/brew "$SHIM"/loginctl \
    "$SHIM"/launchctl "$SHIM"/shlock

# run_drv "<call>" — source the driver with the shim FIRST on PATH and run one
# call (logs reset each time so each case is hermetic). Returns the call's rc.
run_drv() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    PATH="$SHIM:$PATH" NO_COLOR=1 \
        STUB_UNIT_FILES="${STUB_UNIT_FILES-mysql.service enabled enabled
redis-server.service enabled enabled
php-fpm.service disabled disabled
postgresql.service disabled disabled
docker.service disabled disabled}" \
        STUB_BREW_INSTALLED_FORMULAS="${STUB_BREW_INSTALLED_FORMULAS-mysql redis php@8.4 postgresql@17}" \
        bash -c "source '$DRIVER'; $1"
}
calls() { cat "$SHIM_LOG/$1.calls" 2>/dev/null; }

LAUNCHD_HOME="$SANDBOX/launchd-home"
LAUNCHD_STATE="$SANDBOX/launchd-state"
LAUNCHD_LABEL="com.example.daemon"
mkdir -p "$LAUNCHD_HOME/Library/LaunchAgents" "$LAUNCHD_STATE"
: >"$LAUNCHD_HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

# launchd_state_reset <dir> [loaded] [pid] [disabled]
launchd_state_reset() {
    local dir="$1" bit
    shift
    rm -f "$dir/loaded" "$dir/pid" "$dir/disabled" \
        "$dir/failed-enable-once" "$dir/failed-disable-once" \
        "$dir/print-service-count"
    for bit in "$@"; do
        if [[ "$bit" == pid ]]; then
            printf '4242\n' >"$dir/$bit"
        else
            : >"$dir/$bit"
        fi
    done
}

run_drv_launchd() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    HOME="$LAUNCHD_HOME" PATH="$SHIM:$PATH" NO_COLOR=1 \
        STUB_LAUNCHD_LABEL="$LAUNCHD_LABEL" \
        STUB_LAUNCHD_STATE_DIR="$LAUNCHD_STATE" \
        MESH_SERVICES_LAUNCHD_WAIT_ATTEMPTS=1 \
        MESH_SERVICES_LAUNCHD_LOCK_ROOT="$SANDBOX/launchd-locks" \
        bash -c "source '$DRIVER'; $1"
}

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
ASSERT_MSG="Case 8h: brew installed predicate accepts an installed formula" \
    assert_true "run_drv 'svc_installed brew \"\" mysql'"
ASSERT_MSG="Case 8i: brew installed predicate rejects an absent formula" \
    assert_false "STUB_BREW_INSTALLED_FORMULAS= run_drv 'svc_installed brew \"\" mysql'"

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
launchd_state_reset "$LAUNCHD_STATE" loaded pid disabled
run_drv_launchd "svc_enable launchd '' '$LAUNCHD_LABEL'" >/dev/null
assert_contains "$(calls launchctl)" "enable gui/" "Case 11c: launchd enable runs launchctl enable in the gui domain"

launchd_state_reset "$LAUNCHD_STATE" loaded pid disabled
out="$(run_drv_launchd "svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "active=on" \
    "Case 11d: a disabled-but-loaded KeepAlive job remains active"
assert_contains "$out" "enabled=off" \
    "Case 11e: launchd status reads the persistent disabled override instead of equating loaded with enabled"
assert_contains "$(calls launchctl)" "print-disabled gui/" \
    "Case 11f: launchd status queries the canonical disabled map"
assert_contains "$(calls launchctl)" "print gui/$(id -u)/${LAUNCHD_LABEL}" \
    "Case 11fa: launchd probes the same explicit GUI service-target it mutates"
assert_not_contains "$(calls launchctl)" "list ${LAUNCHD_LABEL}" \
    "Case 11fb: launchd status never relies on the legacy implicit-domain list command"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
out="$(run_drv_launchd "export STUB_LAUNCHD_FAIL=print-disabled; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "active=on" \
    "Case 11fc: a disabled-map read failure does not erase a separately observed active PID"
assert_contains "$out" "enabled=unknown" \
    "Case 11fd: a disabled-map read failure is reported as unknown instead of guessed"

out="$(run_drv_launchd "export STUB_LAUNCHD_DISABLED_FORMAT=empty; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "enabled=unknown" \
    "Case 11fe: an empty print-disabled response is rejected as malformed"

launchd_state_reset "$LAUNCHD_STATE" loaded pid disabled
out="$(run_drv_launchd "export STUB_LAUNCHD_DISABLED_FORMAT=boolean; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "enabled=off" \
    "Case 11ff: boolean print-disabled output remains compatible"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
out="$(run_drv_launchd "export STUB_LAUNCHD_DISABLED_FORMAT=absent; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "enabled=on" \
    "Case 11fg: a valid disabled map without the exact target means enabled by default"

out="$(run_drv_launchd "export STUB_LAUNCHD_DISABLED_FORMAT=unquoted; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "enabled=unknown" \
    "Case 11fh: an unrecognised disabled-map entry grammar is rejected instead of mistaken for absence"

out="$(run_drv_launchd "export STUB_LAUNCHD_DISABLED_FORMAT=malformed; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "enabled=unknown" \
    "Case 11fi: a truncated exact-target entry is rejected"

ASSERT_MSG="Case 11fia: launchd installed predicate accepts a persistent plist" \
    assert_true "run_drv_launchd 'svc_installed launchd \"\" \"$LAUNCHD_LABEL\"'"
rm -f "$LAUNCHD_HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
ASSERT_MSG="Case 11fib: launchd installed predicate rejects a missing plist" \
    assert_false "run_drv_launchd 'svc_installed launchd \"\" \"$LAUNCHD_LABEL\"'"
: >"$LAUNCHD_HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"

out="$(run_drv_launchd "export STUB_LAUNCHD_FAIL=print-service; svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "active=unknown" \
    "Case 11fj: a non-not-found service-target error is unknown even when the GUI domain is readable"

launchd_state_reset "$LAUNCHD_STATE"
out="$(run_drv_launchd "svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "active=off" \
    "Case 11g: an unloaded LaunchAgent is inactive"
assert_contains "$out" "enabled=on" \
    "Case 11h: an unloaded persistent plist without a disabled override remains enabled at login"

launchd_state_reset "$LAUNCHD_STATE" loaded pid disabled
run_drv_launchd "svc_stop launchd '' '$LAUNCHD_LABEL'" >/dev/null; rc=$?
assert_eq "$rc" 0 "Case 11i: stop converges a loaded KeepAlive job"
assert_contains "$(calls launchctl)" "bootout --wait gui/$(id -u)/${LAUNCHD_LABEL}" \
    "Case 11j: stop waits for bootout completion instead of using legacy launchctl stop"
ASSERT_MSG="Case 11k: stop leaves the job unloaded so KeepAlive cannot relaunch it" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"
ASSERT_MSG="Case 11ka: stop waits until the launchd process has terminated" \
    assert_false "test -e '$LAUNCHD_STATE/pid'"
ASSERT_MSG="Case 11l: stop preserves the independent disabled bit" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
out="$(run_drv_launchd "svc_status launchd '' '$LAUNCHD_LABEL'")"
assert_contains "$out" "active=off" "Case 11m: stopped launchd state is inactive"
assert_contains "$out" "enabled=off" "Case 11n: stopped launchd state remains disabled"

WATCHDOG_KILL_LOG="$SANDBOX/launchd-watchdog-kill.calls"
rm -f "$WATCHDOG_KILL_LOG"
PATH="$SHIM:$PATH" NO_COLOR=1 bash -c "
    source '$DRIVER'
    launchctl() { return 0; }
    kill() { printf '%s\\n' \"\$*\" >>'$WATCHDOG_KILL_LOG'; return 0; }
    wait() { return 0; }
    sleep() { :; }
    MESH_SERVICES_LAUNCHD_WAIT_ATTEMPTS=1 \
        _svc_launchd_bootout_wait 'gui/501/$LAUNCHD_LABEL'
" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 124 \
    "Case 11na: bootout watchdog reports a timeout when its client never exits"
assert_contains "$(cat "$WATCHDOG_KILL_LOG" 2>/dev/null)" "-KILL" \
    "Case 11nb: bootout watchdog escalates to KILL instead of waiting forever after TERM"

launchd_state_reset "$LAUNCHD_STATE" loaded pid disabled
run_drv_launchd "export STUB_LAUNCHD_NO_EFFECT=bootout; svc_stop launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11o: stop fails when launchctl returns success but the job remains loaded"

launchd_state_reset "$LAUNCHD_STATE"
run_drv_launchd "svc_stop launchd '' '$LAUNCHD_LABEL'" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 \
    "Case 11oa: stop is idempotent when the explicit GUI domain confirms the job is unloaded"

run_drv_launchd "export STUB_LAUNCHD_FAIL=print-domain; svc_stop launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11ob: stop never turns an unreadable GUI domain into a false already-stopped success"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
run_drv_launchd "export STUB_LAUNCHD_FAIL=print-service; svc_stop launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11oc: stop never treats a readable-domain service probe error as already unloaded"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
run_drv_launchd "export STUB_LAUNCHD_NO_EFFECT=disable; svc_disable launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11p: disable fails when launchctl returns success but print-disabled does not converge"

launchd_state_reset "$LAUNCHD_STATE" loaded pid disabled
run_drv_launchd "export STUB_LAUNCHD_NO_EFFECT=enable; svc_enable launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11q: enable fails when launchctl returns success but print-disabled remains disabled"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd "svc_start launchd '' '$LAUNCHD_LABEL'" >/dev/null; rc=$?
assert_eq "$rc" 0 \
    "Case 11r: start bootstraps an unloaded disabled LaunchAgent"
launchd_calls="$(calls launchctl)"
assert_contains "$launchd_calls" "enable gui/$(id -u)/${LAUNCHD_LABEL}" \
    "Case 11s: start temporarily clears the disabled override so bootstrap is allowed"
assert_contains "$launchd_calls" "bootstrap gui/$(id -u) $LAUNCHD_HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist" \
    "Case 11t: start loads the persistent plist"
assert_contains "$launchd_calls" "kickstart gui/$(id -u)/${LAUNCHD_LABEL}" \
    "Case 11ta: start explicitly launches a bootstrapped plist without relying on RunAtLoad or KeepAlive"
assert_contains "$launchd_calls" "disable gui/$(id -u)/${LAUNCHD_LABEL}" \
    "Case 11u: start restores the original disabled bit"
ASSERT_MSG="Case 11v: start reaches the active post-condition" \
    assert_true "test -e '$LAUNCHD_STATE/pid'"
ASSERT_MSG="Case 11w: start does not silently enable login autostart" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd "export STUB_LAUNCHD_FAIL=bootstrap; svc_start launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 "Case 11x: a failed bootstrap makes start fail"
ASSERT_MSG="Case 11y: failed bootstrap restores the original disabled bit" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
ASSERT_MSG="Case 11z: failed bootstrap leaves the originally unloaded job unloaded" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd "export STUB_LAUNCHD_FAIL_ONCE=disable; svc_start launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11za: a failed first disabled-state restoration never produces success"
ASSERT_MSG="Case 11zb: rollback retries and restores disabled after the transient failure" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
ASSERT_MSG="Case 11zc: rollback unloads the partially started job" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd "export STUB_LAUNCHD_RACE=bootstrap; svc_start launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 \
    "Case 11zd: a concurrent load that wins the bootstrap race still converges start"
ASSERT_MSG="Case 11ze: concurrent job remains loaded instead of being rolled back by this invocation" \
    assert_true "test -e '$LAUNCHD_STATE/loaded'"
ASSERT_MSG="Case 11zf: concurrent convergence restores the original disabled bit" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
assert_not_contains "$(calls launchctl)" "bootout" \
    "Case 11zg: failed bootstrap never bootouts a job it may not own"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd 'export STUB_LAUNCHD_SIGNAL_ON=bootstrap STUB_LAUNCHD_SIGNAL=INT STUB_LAUNCHD_SIGNAL_PID=$$; svc_start launchd "" com.example.daemon' \
    >/dev/null 2>&1; rc=$?
assert_eq "$rc" 130 \
    "Case 11zh: SIGINT inside the temporary-enable window is propagated after cleanup"
ASSERT_MSG="Case 11zi: interrupted start restores the original disabled bit" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
ASSERT_MSG="Case 11zj: interrupted start rolls back the job loaded by this invocation" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd 'export STUB_LAUNCHD_SIGNAL_ON=bootstrap STUB_LAUNCHD_SIGNAL=HUP STUB_LAUNCHD_SIGNAL_PID=$$; svc_start launchd "" com.example.daemon' \
    >/dev/null 2>&1; rc=$?
assert_eq "$rc" 129 \
    "Case 11zk: SIGHUP is propagated after cleanup with its conventional exit code"
ASSERT_MSG="Case 11zl: SIGHUP cleanup restores the original disabled bit" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
ASSERT_MSG="Case 11zm: SIGHUP cleanup unloads the job created by start" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd 'export STUB_LAUNCHD_SIGNAL_ON=bootstrap STUB_LAUNCHD_SIGNAL=INT STUB_LAUNCHD_SIGNAL_RESULT=fail STUB_LAUNCHD_SIGNAL_PID=$$; svc_start launchd "" com.example.daemon' \
    >/dev/null 2>&1; rc=$?
assert_eq "$rc" 130 \
    "Case 11zn: interrupted bootstrap failure propagates SIGINT"
ASSERT_MSG="Case 11zo: interrupted partial bootstrap restores disabled" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
ASSERT_MSG="Case 11zp: interrupted partial bootstrap restores the original unloaded state" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
old_pid="$(awk 'NR == 1 { print; exit }' "$LAUNCHD_STATE/pid")"
run_drv_launchd "svc_restart launchd '' '$LAUNCHD_LABEL'" >/dev/null 2>&1; rc=$?
new_pid="$(awk 'NR == 1 { print; exit }' "$LAUNCHD_STATE/pid")"
assert_eq "$rc" 0 "Case 11zq: restart succeeds when launchd replaces the process"
assert_ne "$new_pid" "$old_pid" "Case 11zr: restart observes a new PID"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
run_drv_launchd "export STUB_LAUNCHD_NO_EFFECT=kickstart; svc_restart launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11zs: restart rejects rc0 when kickstart leaves the old PID running"

launchd_state_reset "$LAUNCHD_STATE" loaded pid
run_drv_launchd "export STUB_LAUNCHD_FAIL_PRINT_SERVICE_AT=2 STUB_LAUNCHD_NO_EFFECT=kickstart; svc_restart launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 \
    "Case 11zsa: restart rejects an unreadable pre-kickstart PID instead of accepting the old process"
assert_not_contains "$(calls launchctl)" "kickstart -k" \
    "Case 11zsb: restart does not mutate when it cannot establish the old PID post-condition"

launchd_state_reset "$LAUNCHD_STATE" disabled
LOCK_FIXTURE="$SANDBOX/launchd-locks/${LAUNCHD_LABEL}.lock"
printf '%s\n' "$$" >"$LOCK_FIXTURE"
run_drv_launchd "svc_start launchd '' '$LAUNCHD_LABEL'" >/dev/null 2>&1; rc=$?
assert_ne "$rc" 0 "Case 11zt: a concurrent mesh launchd mutation is rejected"
ASSERT_MSG="Case 11zu: lock contention leaves disabled unchanged" \
    assert_true "test -e '$LAUNCHD_STATE/disabled'"
ASSERT_MSG="Case 11zv: lock contention never loads the job" \
    assert_false "test -e '$LAUNCHD_STATE/loaded'"
rm -f "$LOCK_FIXTURE"

launchd_state_reset "$LAUNCHD_STATE" disabled
rm -f "$LOCK_FIXTURE"
bash -c ':' &
STALE_LOCK_OWNER=$!
wait "$STALE_LOCK_OWNER"
printf '%s\n' "$STALE_LOCK_OWNER" >"$LOCK_FIXTURE"
SHLOCK_DELAY_MARKER="$SANDBOX/shlock-stale-delay-used"
rm -f "$SHLOCK_DELAY_MARKER"
run_drv_launchd "export STUB_SHLOCK_STALE_DELAY_MARKER='$SHLOCK_DELAY_MARKER'; svc_start launchd '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 \
    "Case 11zw: an abandoned PID lock is recovered by the atomic lock primitive"
assert_contains "$(calls shlock)" "-f $LOCK_FIXTURE" \
    "Case 11zx: launchd mutations delegate stale-safe acquisition to shlock"
assert_eq "$(wc -l <"$SHIM_LOG/shlock.calls" | tr -d ' ')" 2 \
    "Case 11zxa: a just-stale shlock is retried after its conservative first refusal"
ASSERT_MSG="Case 11zy: successful mutation releases its PID lock" \
    assert_false "test -e '$LOCK_FIXTURE'"

launchd_state_reset "$LAUNCHD_STATE" disabled
run_drv_launchd "interrupted_impl() { kill -TERM \$\$; }; _svc_launchd_with_lock interrupted_impl '' '$LAUNCHD_LABEL'" \
    >/dev/null 2>&1; rc=$?
assert_eq "$rc" 143 \
    "Case 11zz: a signal can terminate a launchd mutation process"
ASSERT_MSG="Case 11zza: the interrupted process leaves a diagnosable PID lock" \
    assert_true "test -f '$LOCK_FIXTURE'"
run_drv_launchd "svc_start launchd '' '$LAUNCHD_LABEL'" >/dev/null 2>&1; rc=$?
assert_eq "$rc" 0 \
    "Case 11zzb: the next mutation safely recovers the interrupted process's stale lock"
ASSERT_MSG="Case 11zzc: recovery removes the lock after the next successful mutation" \
    assert_false "test -e '$LOCK_FIXTURE'"

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
    PATH="$SHIM:$PATH" MESH_SERVICES_OS=wsl NO_COLOR=1 \
        STUB_UNIT_FILES="${STUB_UNIT_FILES-mysql.service enabled enabled
redis-server.service enabled enabled
php-fpm.service disabled disabled
postgresql.service disabled disabled
docker.service disabled disabled}" \
        bash "$RUNNER" "$@"
}

# Exact macOS regression fixture: the non-canonical Homebrew path installs
# Oracle MySQL under /usr/local and owns its run layer through this user
# LaunchAgent. Brew intentionally reports no running mysql service.
MAC_MYSQL_HOME="$SANDBOX/mac-mysql-home"
MAC_MYSQL_LABEL="com.mesh-test.mysql"
mkdir -p "$MAC_MYSQL_HOME/Library/LaunchAgents"
: > "$MAC_MYSQL_HOME/Library/LaunchAgents/${MAC_MYSQL_LABEL}.plist"
run_svc_mac_mysql() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    HOME="$MAC_MYSQL_HOME" USER=mesh-test PATH="$SHIM:$PATH" \
        STUB_BREW_MYSQL="${STUB_BREW_MYSQL:-none}" \
        STUB_BREW_INSTALLED_FORMULAS="${STUB_BREW_INSTALLED_FORMULAS-mysql redis php@8.4 postgresql@17}" \
        STUB_LAUNCHD_LABEL="${STUB_LAUNCHD_LABEL:-$MAC_MYSQL_LABEL}" \
        STUB_LAUNCHD_LOADED="${STUB_LAUNCHD_LOADED:-1}" \
        STUB_LAUNCHD_PID="${STUB_LAUNCHD_PID:-1}" \
        MESH_SERVICES_OS=mac NO_COLOR=1 bash "$RUNNER" "$@"
}
run_svc_mac_brew() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    HOME="$REGISTRY_HOME" USER=mesh-test PATH="$SHIM:$PATH" \
        STUB_BREW_MYSQL="${STUB_BREW_MYSQL:-none}" \
        STUB_BREW_INSTALLED_FORMULAS="${STUB_BREW_INSTALLED_FORMULAS-mysql redis php@8.4 postgresql@17}" \
        MESH_SERVICES_OS=mac NO_COLOR=1 bash "$RUNNER" "$@"
}

MAC_MYSQL_STATE="$SANDBOX/mac-mysql-state"
mkdir -p "$MAC_MYSQL_STATE"
run_svc_mac_mysql_state() {
    rm -f "$SHIM_LOG"/*.calls 2>/dev/null
    HOME="$MAC_MYSQL_HOME" USER=mesh-test PATH="$SHIM:$PATH" \
        STUB_BREW_MYSQL=none \
        STUB_LAUNCHD_LABEL="$MAC_MYSQL_LABEL" \
        STUB_LAUNCHD_STATE_DIR="$MAC_MYSQL_STATE" \
        STUB_LAUNCHD_NO_EFFECT="${STUB_LAUNCHD_NO_EFFECT:-}" \
        STUB_LAUNCHD_FAIL="${STUB_LAUNCHD_FAIL:-}" \
        MESH_SERVICES_LAUNCHD_WAIT_ATTEMPTS=1 \
        MESH_SERVICES_LAUNCHD_LOCK_ROOT="$SANDBOX/launchd-locks" \
        MESH_SERVICES_OS=mac NO_COLOR=1 bash "$RUNNER" "$@"
}

# ─── Case 12: `list` (human) — badges + owner + header ───────────────────────
out="$(run_svc list 2>&1)"; rc=$?
assert_eq "$rc" "0" "Case 12z: list exits 0 for a healthy default listing"
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

out="$(run_svc_mac_mysql list --porcelain)"
assert_contains "$out" "mysql|MySQL|mysqld|databases|launchd||${MAC_MYSQL_LABEL}|on|on" \
    "Case 14e: Oracle MySQL's mesh LaunchAgent is reported running/on-boot instead of the absent brew service"
assert_contains "$(calls launchctl)" "print gui/$(id -u)/${MAC_MYSQL_LABEL}" \
    "Case 14f: Oracle MySQL status queries its explicit GUI LaunchAgent target"

out="$(STUB_LAUNCHD_PID=0 run_svc_mac_mysql list --porcelain)"
assert_contains "$out" "mysql|MySQL|mysqld|databases|launchd||${MAC_MYSQL_LABEL}|off|on" \
    "Case 14g: a loaded Oracle MySQL LaunchAgent without a PID stays on-boot but is stopped"

launchd_state_reset "$MAC_MYSQL_STATE" loaded pid
run_svc_mac_mysql_state restart mysql >/dev/null
assert_contains "$(calls launchctl)" "kickstart -k gui/$(id -u)/${MAC_MYSQL_LABEL}" \
    "Case 14h: Oracle MySQL restart targets its LaunchAgent"
assert_not_contains "$(calls brew)" "services restart mysql" \
    "Case 14i: Oracle MySQL restart never targets the unrelated brew formula"

out="$(STUB_BREW_MYSQL=started run_svc_mac_brew list --porcelain)"
assert_contains "$out" "mysql|MySQL|mysqld|databases|brew||mysql|on|on" \
    "Case 14j: a canonical brew MySQL service keeps the brew backend and running/on-boot state"
out="$(STUB_BREW_INSTALLED_FORMULAS= STUB_BREW_MYSQL=none run_svc_mac_brew list --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 14k: default porcelain list exits 0 when no curated mac services are installed"
assert_eq "$out" "" \
    "Case 14ka: default porcelain list omits uninstalled mac brew services instead of printing stopped/no-boot"
out="$(STUB_BREW_INSTALLED_FORMULAS= STUB_BREW_MYSQL=none run_svc_mac_brew list 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 14kb: human list exits 0 when every curated mac service is uninstalled"
assert_contains "$out" "No installed mesh-owned services" \
    "Case 14kc: human list explains that no curated services are installed"
assert_not_contains "$out" "mysql" \
    "Case 14kd: human default list does not print the uninstalled mysql row"
out="$(STUB_BREW_INSTALLED_FORMULAS= STUB_BREW_MYSQL=none run_svc_mac_brew list --all --porcelain 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 14ke: --all remains a successful explicit inventory view"
assert_contains "$out" "mysql|MySQL|mysqld|databases|brew||mysql|off|off" \
    "Case 14kf: --all can still show the curated absent/stopped brew descriptor"

# $1 is expanded by the child bash.
# shellcheck disable=SC2016
out="$(env -u HOME USER=mesh-test bash -c 'source "$1"; svcdef_mysql_mac' _ \
    "$REPO_ROOT/scripts/lib/services/registry/mysql.sh")"
assert_eq "$out" "brew||mysql" \
    "Case 14l: missing HOME falls back safely to the brew backend"

FALLBACK_HOME="$SANDBOX/mac-mysql-fallback-home"
FALLBACK_BIN="$SANDBOX/mac-mysql-fallback-bin"
mkdir -p "$FALLBACK_HOME/Library/LaunchAgents" "$FALLBACK_BIN"
: > "$FALLBACK_HOME/Library/LaunchAgents/com.mesh-fallback.mysql.plist"
cat > "$FALLBACK_BIN/id" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == -un ]] && { echo mesh-fallback; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod +x "$FALLBACK_BIN/id"
# $1 is expanded by the child bash.
# shellcheck disable=SC2016
out="$(env -u USER HOME="$FALLBACK_HOME" PATH="$FALLBACK_BIN:$PATH" \
    bash -c 'source "$1"; svcdef_mysql_mac' _ \
    "$REPO_ROOT/scripts/lib/services/registry/mysql.sh")"
assert_eq "$out" "launchd||com.mesh-fallback.mysql" \
    "Case 14m: missing USER derives the LaunchAgent label from id -un"

# Exact end-to-end reproduction of the operator's sequence. The stateful shim
# models KeepAlive, so legacy `launchctl stop` returns 0 but immediately leaves
# the job running; only a verified bootout can make this contract pass.
launchd_state_reset "$MAC_MYSQL_STATE" loaded pid
out="$(run_svc_mac_mysql_state disable mysql 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 14n: disabling the running MySQL LaunchAgent succeeds"
ASSERT_MSG="Case 14o: disable persists the no-boot override" \
    assert_true "test -e '$MAC_MYSQL_STATE/disabled'"
ASSERT_MSG="Case 14p: disable does not stop the running service" \
    assert_true "test -e '$MAC_MYSQL_STATE/pid'"

out="$(run_svc_mac_mysql_state stop mysql 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 14q: stopping the disabled KeepAlive MySQL LaunchAgent succeeds"
ASSERT_MSG="Case 14r: stop unloads MySQL instead of allowing KeepAlive to relaunch it" \
    assert_false "test -e '$MAC_MYSQL_STATE/loaded'"
ASSERT_MSG="Case 14s: stop preserves MySQL's disabled override" \
    assert_true "test -e '$MAC_MYSQL_STATE/disabled'"

out="$(run_svc_mac_mysql_state status mysql 2>&1)"
assert_contains "$out" "active  : stopped" \
    "Case 14t: status after disable+stop reports MySQL stopped"
assert_contains "$out" "enabled : no-boot" \
    "Case 14u: status after disable+stop reports MySQL disabled at login"

launchd_state_reset "$MAC_MYSQL_STATE" loaded pid disabled
out="$(STUB_LAUNCHD_NO_EFFECT=bootout run_svc_mac_mysql_state stop mysql 2>&1)"; rc=$?
assert_ne "$rc" 0 \
    "Case 14v: runner rejects a false launchctl success when MySQL remains loaded"
assert_contains "$out" "stop failed" \
    "Case 14w: runner surfaces the failed stop post-condition"
assert_not_contains "$out" "✓ MySQL: stop" \
    "Case 14x: runner never prints a success checkmark before stop converges"

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

export STUB_SYSTEMCTL_FAIL='stop mysql'
export STUB_SYSTEMCTL_FAIL_RC=130
out="$(run_svc stop mysql redis 2>&1)"; rc=$?
unset STUB_SYSTEMCTL_FAIL STUB_SYSTEMCTL_FAIL_RC
sudo_calls="$(calls sudo)"
assert_eq "$rc" 130 \
    "Case 20c: a signal-derived backend result is preserved by the runner"
assert_contains "$sudo_calls" "systemctl stop mysql" \
    "Case 20d: the interrupted service was attempted"
assert_not_contains "$sudo_calls" "systemctl stop redis-server" \
    "Case 20e: a signal aborts the batch before later services are mutated"

# ─── Case 21: command-module wiring (structural; live dispatch is G-2) ───────
MESH="$REPO_ROOT/bin/mesh"
SERVICES_MODULE="$REPO_ROOT/scripts/commands/services.sh"
ASSERT_MSG="Case 21a: services command module exists" assert_true "test -f '$SERVICES_MODULE'"
ASSERT_MSG="Case 21b: services registers through the command module" \
    assert_true "grep -q 'mesh_register_command' '$SERVICES_MODULE'"

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

# ─── Case 30: services carries the non-interactive fan-out env (structural) ──
ASSERT_MSG="Case 30: services registers its fan-out validator and non-interactive env provider" \
    assert_true "grep -q -- '--fanout-validator _mesh_fanout_validate_services' '$SERVICES_MODULE' && grep -q -- '--fanout-env-provider _mesh_fanout_env_noninteractive' '$SERVICES_MODULE'"

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

# ─── Case 33j-k: install-path alias resolution sources mesh-status.conf (O-1) ──
# A topic installer under setup.sh has no MESH_SERVICES_ALIAS exported; the file
# must still resolve to services.default.<alias>, NOT services.default.<hostname>.
RECON_LIB="$REPO_ROOT/scripts/lib/services/reconcile.sh"
CONF_STUB="$SANDBOX/mesh-status.conf"; printf 'MESH_HOST_ALIAS=zeta\n' > "$CONF_STUB"
p_alias="$(env -u MESH_SERVICES_ALIAS -u MESH_HOST_ALIAS -u MESH_SERVICES_DEFAULT \
    MESH_STATUS_CONF="$CONF_STUB" MESH_IDENTITY_DIR=/id \
    bash -c 'source "$1"; services_default_path' _ "$RECON_LIB")"
assert_eq "$p_alias" "/id/config/services.default.zeta" \
    "Case 33j: services_default_path resolves <alias> from mesh-status.conf MESH_HOST_ALIAS (not the raw hostname)"
p_override="$(env -u MESH_SERVICES_DEFAULT MESH_SERVICES_ALIAS=crc \
    MESH_STATUS_CONF="$CONF_STUB" MESH_IDENTITY_DIR=/id \
    bash -c 'source "$1"; services_default_path' _ "$RECON_LIB")"
assert_eq "$p_override" "/id/config/services.default.crc" \
    "Case 33k: an explicit MESH_SERVICES_ALIAS overrides the conf alias"
# An uppercase hostname (crc: CRCMG005078) must map through MESH_TAILSCALE_ALIAS_MAP
# (lowercase-keyed) to its alias — the metal-found gap where reconcile resolved the
# raw hostname. Stub `hostname` + an empty conf so only the env map drives it.
HN_SHIM="$SANDBOX/hnbin"; mkdir -p "$HN_SHIM"
printf '#!/usr/bin/env bash\necho CRCMG005078\n' > "$HN_SHIM/hostname"; chmod +x "$HN_SHIM/hostname"
: > "$SANDBOX/empty.conf"
p_map="$(env -u MESH_SERVICES_ALIAS -u MESH_HOST_ALIAS -u MESH_SERVICES_DEFAULT \
    PATH="$HN_SHIM:$PATH" MESH_STATUS_CONF="$SANDBOX/empty.conf" \
    MESH_TAILSCALE_ALIAS_MAP='{"crcmg005078":"crc"}' MESH_IDENTITY_DIR=/id \
    bash -c 'source "$1"; services_default_path' _ "$RECON_LIB")"
assert_eq "$p_map" "/id/config/services.default.crc" \
    "Case 33l: an uppercase hostname maps through MESH_TAILSCALE_ALIAS_MAP (lowercased) to the alias"

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

# ─── Case 37c-f: reconcile SKIPS a non-orthogonal (brew) backend ──────────────
# Explicit `reconcile <name>` on mac resolves mysql → brew||mysql. brew couples
# the two bits (svc_enable=`brew services start` also runs, svc_disable=`brew
# services stop` also stops), so reconcile — enabled-bit only — must SKIP it
# rather than start/stop a running unit. The collateral guard cmd_action honours,
# applied to reconcile (regression test for the silent start/stop bug).
rm -f "$SHIM_LOG"/*.calls 2>/dev/null
out="$(HOME="$REGISTRY_HOME" USER=mesh-test PATH="$SHIM:$PATH" \
    MESH_SERVICES_OS=mac NO_COLOR=1 bash "$RUNNER" reconcile mysql 2>&1)"; rc=$?
brew_calls="$(calls brew)"
assert_eq "$rc" 0 "Case 37c: reconcile of a brew (non-orthogonal) service exits 0 (skipped, not failed)"
assert_contains "$out" "skipped" "Case 37d: reconcile reports the brew service skipped (couples boot+runtime)"
assert_not_contains "$brew_calls" "services start" "Case 37e: reconcile never 'brew services start' (no collateral run)"
assert_not_contains "$brew_calls" "services stop"  "Case 37f: reconcile never 'brew services stop' (no collateral stop)"

# ─── Case 37g-h: services.default is authoritative OUTSIDE the opt-out set (O-2) ─
# gamma is curated but NOT opt-out; a services.default opt-in must still reconcile
# it (this is the mechanism that was a silent no-op on mac, where nothing is opt-out).
export STUB_ENABLED=disabled
out="$(run_svc_recon $'gamma\n' 2>&1)"; rc=$?
sudo_calls="$(calls sudo)"
assert_eq "$rc" 0 "Case 37g: reconcile of a non-opt-out opted-in service (gamma) exits 0"
assert_contains "$sudo_calls" "systemctl enable gammaunit" \
    "Case 37h: a services.default opt-in OUTSIDE the opt-out set is enabled (services.default authoritative)"
unset STUB_ENABLED

# ─── Case 37i-j: a stale/unknown services.default entry warns, never fails ────
export STUB_ENABLED=enabled
out="$(run_svc_recon $'nonsuch-xyz\n' 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 37i: an unresolved services.default entry does not fail reconcile (mesh update stays green)"
assert_contains "$out" "no such curated service" "Case 37j: ...and warns about the ignored entry"
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
