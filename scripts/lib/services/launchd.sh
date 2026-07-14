# shellcheck shell=bash
# scripts/lib/services/launchd.sh — launchd backend for non-brew mac daemons.
#
# launchd separates the two bits (enable/disable persist a label across logins;
# kickstart/bootstrap/bootout are runtime), so svc_launchd_orthogonal returns 0.
# Operates in the per-user GUI domain (gui/<uid>). Descriptor scope is empty;
# target = the launchd label (e.g. com.example.daemon). Sourced; no set -e.
#
# A loaded job is NOT necessarily enabled: `launchctl disable` records a
# persistent override without unloading a running job. Conversely, `bootout`
# unloads a job without removing its plist or changing that override. Keep those
# states independent throughout this backend.

_svc_launchd_domain() { printf 'gui/%s' "$(id -u)"; }

_svc_launchd_target() {
    printf '%s/%s' "$(_svc_launchd_domain)" "$1"
}

_svc_launchd_plist() {
    [[ -n "${HOME:-}" ]] || return 1
    printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$1"
}

# _svc_launchd_loaded_state <label> — print on/off only after probing the exact
# GUI domain used by mutations. A failed service probe is "off" only when the
# parent domain itself remains readable; otherwise return unknown (non-zero).
_svc_launchd_loaded_state() {
    local label="$1" domain target rc
    domain="$(_svc_launchd_domain)"
    target="${domain}/${label}"
    if launchctl print "$target" >/dev/null 2>&1; then
        printf 'on'
    else
        rc=$?
        # Current launchctl uses 113 for a missing service target. Any other
        # failure is an unreadable/unknown state, even when the parent domain
        # itself remains readable.
        (( rc == 113 )) || return 1
        launchctl print "$domain" >/dev/null 2>&1 || return 1
        printf 'off'
    fi
}

_svc_launchd_output_has_pid() {
    local out="$1"
    awk '$1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { found=1 }
         END { exit(found ? 0 : 1) }' <<<"$out"
}

_svc_launchd_is_active() {
    [[ -n "$(_svc_launchd_pid "$1")" ]]
}

_svc_launchd_pid() {
    local out
    out="$(launchctl print "$(_svc_launchd_target "$1")" 2>/dev/null)" || return 1
    awk '$1 == "pid" && $2 == "=" && $3 ~ /^[0-9]+$/ { print $3; exit }' <<<"$out"
}

# _svc_launchd_enabled_state <label> — print on/off from launchd's persistent
# disabled map. A missing entry means enabled (launchd's default). Accept both
# output vocabularies seen across macOS releases: enabled/disabled and
# false/true. Query/parse failures are returned, never guessed.
_svc_launchd_enabled_state() {
    local label="$1" out token
    out="$(launchctl print-disabled "$(_svc_launchd_domain)" 2>/dev/null)" || return 1
    case "$out" in
        *'disabled services = {'*'}'*) ;;
        *) return 1 ;;
    esac
    token="$(awk -v key="\"$label\"" '
        BEGIN { header=0; closed=0; invalid=0; found=0; target="" }
        NF == 0 { next }
        $1 == "disabled" && $2 == "services" && $3 == "=" && $4 == "{" {
            header++
            next
        }
        $1 == "}" { closed++; next }
        {
            entry=$1
            separator=$2
            value=$3
            sub(/[;,]$/, "", value)
            if (entry !~ /^"[^"]+"$/ || separator != "=>" || NF < 3 \
                || value !~ /^(enabled|disabled|true|false)$/) {
                invalid=1
                next
            }
            if (entry == key) {
                if (found) invalid=1
                found=1
                target=value
            }
        }
        END {
            if (header != 1 || closed < 1 || invalid) print "__invalid__"
            else if (found) print target
            else print "__absent__"
        }
    ' <<<"$out")" || return 1
    case "$token" in
        disabled|true)    printf 'off' ;;
        enabled|false|__absent__) printf 'on' ;;
        *)                return 1 ;;
    esac
}

_svc_launchd_wait_count() {
    local count="${MESH_SERVICES_LAUNCHD_WAIT_ATTEMPTS:-50}"
    case "$count" in ''|*[!0-9]*) count=50 ;; esac
    (( count > 0 )) || count=1
    printf '%s' "$count"
}

_svc_launchd_wait_active() {
    local label="$1" count i
    count="$(_svc_launchd_wait_count)"
    i=1
    while (( i <= count )); do
        _svc_launchd_is_active "$label" && return 0
        (( i < count )) && sleep 0.1
        i=$((i + 1))
    done
    return 1
}

_svc_launchd_wait_restarted() {
    local label="$1" old_pid="$2" count i current
    count="$(_svc_launchd_wait_count)"
    i=1
    while (( i <= count )); do
        current="$(_svc_launchd_pid "$label")" || current=""
        if [[ -n "$current" && "$current" != "$old_pid" ]]; then return 0; fi
        (( i < count )) && sleep 0.1
        i=$((i + 1))
    done
    return 1
}

# `launchctl bootout --wait` proves the service process has finished, but Apple
# warns that it may block indefinitely. Run it under the same bounded polling
# budget used by the other post-conditions and terminate only the waiting client
# on timeout; callers still report failure and never print a premature success.
_svc_launchd_bootout_wait() {
    local target="$1" count i waiter rc
    launchctl bootout --wait "$target" &
    waiter=$!
    count="$(_svc_launchd_wait_count)"
    i=1
    while (( i <= count )); do
        if ! kill -0 "$waiter" 2>/dev/null; then
            wait "$waiter"
            return $?
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if ! kill -0 "$waiter" 2>/dev/null; then
        wait "$waiter"
        rc=$?
        return "$rc"
    fi

    # TERM gets one bounded grace window. Never follow it with an unbounded
    # wait: a wedged launchctl client is precisely why this watchdog exists.
    kill -TERM "$waiter" 2>/dev/null || true
    i=1
    while (( i <= count )); do
        if ! kill -0 "$waiter" 2>/dev/null; then
            wait "$waiter" 2>/dev/null || true
            printf 'mesh services: launchd bootout timed out for %s\n' "$target" >&2
            return 124
        fi
        sleep 0.1
        i=$((i + 1))
    done
    if kill -0 "$waiter" 2>/dev/null; then
        kill -KILL "$waiter" 2>/dev/null || true
        # Do not wait here: even after KILL an uninterruptible client could
        # keep wait(1) blocked. Bash will reap the background child later.
    else
        wait "$waiter" 2>/dev/null || true
    fi
    printf 'mesh services: launchd bootout timed out for %s\n' "$target" >&2
    return 124
}

_svc_launchd_wait_unloaded() {
    local label="$1" count i observed
    count="$(_svc_launchd_wait_count)"
    i=1
    while (( i <= count )); do
        observed="$(_svc_launchd_loaded_state "$label")" \
            && [[ "$observed" == off ]] \
            && return 0
        (( i < count )) && sleep 0.1
        i=$((i + 1))
    done
    return 1
}

_svc_launchd_wait_enabled() {
    local label="$1" expected="$2" count i observed
    count="$(_svc_launchd_wait_count)"
    i=1
    while (( i <= count )); do
        observed="$(_svc_launchd_enabled_state "$label")" \
            && [[ "$observed" == "$expected" ]] \
            && return 0
        (( i < count )) && sleep 0.1
        i=$((i + 1))
    done
    return 1
}

_svc_launchd_failed() {
    printf 'mesh services: launchd %s did not reach its post-condition for %s\n' \
        "$1" "$2" >&2
    return 1
}

svc_launchd_orthogonal() { return 0; }

svc_launchd_status() {
    local label="$2" domain target out active enabled persistent plist probe_rc
    domain="$(_svc_launchd_domain)"
    target="${domain}/${label}"
    if out="$(launchctl print "$target" 2>/dev/null)"; then
        if _svc_launchd_output_has_pid "$out"; then
            active=on
        else
            active=off
        fi
    else
        probe_rc=$?
        if (( probe_rc == 113 )) && launchctl print "$domain" >/dev/null 2>&1; then
            active=off
        else
            active=unknown
        fi
    fi

    if persistent="$(_svc_launchd_enabled_state "$label")"; then
        if [[ "$persistent" == off ]]; then
            enabled=off
        elif plist="$(_svc_launchd_plist "$label")" && [[ -f "$plist" ]]; then
            enabled=on
        else
            # An enabled override without a persistent plist cannot load at the
            # next login, so do not advertise it as on-boot.
            enabled=off
        fi
    else
        enabled=unknown
    fi
    printf 'active=%s\nenabled=%s\northogonal=yes\n' "$active" "$enabled"
}

_svc_launchd_lock_path() {
    local label="$1" root safe fallback_root
    fallback_root="${TMPDIR:-/tmp}/mesh-services-$(id -u)-launchd-locks"
    root="${MESH_SERVICES_LAUNCHD_LOCK_ROOT:-$fallback_root}"
    safe="$(printf '%s' "$label" | tr -c '[:alnum:]_.-' '_')"
    printf '%s/%s.lock' "$root" "$safe"
}

_svc_launchd_lock_acquire() {
    local label="$1" lock root owner="" attempt=1 acquired=0
    lock="$(_svc_launchd_lock_path "$label")"
    root="${lock%/*}"
    mkdir -p "$root" || return 1

    # launchd is a macOS-only backend. shlock uses link(2) for atomic acquisition
    # and validates the recorded PID before safely replacing a stale lock. That
    # covers both concurrent stale reapers and a prior process killed mid-action.
    if ! command -v shlock >/dev/null 2>&1; then
        printf 'mesh services: launchd mutations require shlock\n' >&2
        return 69
    fi
    while (( attempt <= 15 )); do
        if shlock -p "$$" -f "$lock" >/dev/null 2>&1; then
            acquired=1
            break
        fi

        # shlock intentionally refuses a just-created stale lock until its
        # ctime is older than the contender's temporary claim (one-second time
        # granularity on macOS). Retry only after proving the recorded PID is
        # gone; a live/unknown owner remains an immediate fail-closed result.
        owner=""
        [[ -r "$lock" ]] && owner="$(awk 'NR == 1 { print; exit }' "$lock")"
        case "$owner" in
            ''|*[!0-9]*) break ;;
            *) kill -0 "$owner" 2>/dev/null && break ;;
        esac
        (( attempt < 15 )) || break
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if (( ! acquired )); then
        printf 'mesh services: launchd mutation already in progress for %s\n' "$label" >&2
        return 75
    fi
    printf '%s' "$lock"
}

_svc_launchd_lock_release() {
    local lock="$1" owner=""
    [[ -r "$lock" ]] && owner="$(awk 'NR == 1 { print; exit }' "$lock")"
    if [[ "$owner" != "$$" ]]; then
        printf 'mesh services: launchd lock ownership changed: %s\n' "$lock" >&2
        return 1
    fi
    rm -f "$lock"
}

_svc_launchd_with_lock() {
    local impl="$1" scope="$2" label="$3" lock rc signal=""
    lock="$(_svc_launchd_lock_acquire "$label")"
    rc=$?
    (( rc == 0 )) || return "$rc"

    "$impl" "$scope" "$label"
    rc=$?
    if ! _svc_launchd_lock_release "$lock"; then
        (( rc == 0 )) && rc=1
    fi

    # The start transaction consumes signals only long enough to restore its
    # temporary enabled bit. Re-deliver after releasing the lock so the caller's
    # original/default handler runs and a batch cannot continue mutating.
    case "$rc" in
        129) signal=HUP ;;
        130) signal=INT ;;
        143) signal=TERM ;;
    esac
    if [[ -n "$signal" ]]; then
        kill -s "$signal" "$$"
    fi
    return "$rc"
}

_svc_launchd_enable_impl() {
    local label="$2" target plist
    target="$(_svc_launchd_target "$label")"
    plist="$(_svc_launchd_plist "$label")" || {
        printf 'mesh services: launchd enable needs HOME to locate %s.plist\n' "$label" >&2
        return 1
    }
    if [[ ! -f "$plist" ]]; then
        printf 'mesh services: launchd enable cannot find plist: %s\n' "$plist" >&2
        return 1
    fi
    launchctl enable "$target" || return $?
    _svc_launchd_wait_enabled "$label" on \
        || _svc_launchd_failed enable "$label"
}

_svc_launchd_disable_impl() {
    local label="$2" target
    target="$(_svc_launchd_target "$label")"
    launchctl disable "$target" || return $?
    _svc_launchd_wait_enabled "$label" off \
        || _svc_launchd_failed disable "$label"
}

_svc_launchd_stop_impl() {
    local label="$2" target loaded
    target="$(_svc_launchd_target "$label")"

    # Idempotent when already unloaded. `launchctl stop` is intentionally not
    # used: a loaded KeepAlive job will simply respawn, as MySQL demonstrated.
    loaded="$(_svc_launchd_loaded_state "$label")" || {
        printf 'mesh services: launchd cannot read GUI-domain state for %s\n' "$label" >&2
        return 1
    }
    [[ "$loaded" == off ]] && return 0
    _svc_launchd_bootout_wait "$target" || return $?
    _svc_launchd_wait_unloaded "$label" \
        || _svc_launchd_failed stop "$label"
}

# Bootstrap an unloaded plist while preserving the persistent enabled bit. A
# disabled service cannot be bootstrapped, so temporarily enable it, load it,
# then restore disabled. A failed transaction attempts a verified rollback and
# reports explicitly if launchd prevents complete restoration.
_svc_launchd_restore_trap() {
    local saved="$1" signal="$2"
    if [[ -n "$saved" ]]; then
        eval "$saved"
    else
        trap - "$signal"
    fi
}

_svc_launchd_start_unloaded() {
    local label="$1" domain target plist original loaded bootstrap_output=""
    local restore=0 bootstrapped=0 runtime_ok=0 failed=0 rollback_failed=0
    local traps_set=0 interrupted=0 old_hup="" old_int="" old_term=""
    domain="$(_svc_launchd_domain)"
    target="${domain}/${label}"
    plist="$(_svc_launchd_plist "$label")" || {
        printf 'mesh services: launchd start needs HOME to locate %s.plist\n' "$label" >&2
        return 1
    }
    if [[ ! -f "$plist" ]]; then
        printf 'mesh services: launchd start cannot find plist: %s\n' "$plist" >&2
        return 1
    fi
    original="$(_svc_launchd_enabled_state "$label")" || {
        printf 'mesh services: launchd cannot read enabled state for %s\n' "$label" >&2
        return 1
    }

    if [[ "$original" == off ]]; then
        restore=1
        old_hup="$(trap -p HUP)"
        old_int="$(trap -p INT)"
        old_term="$(trap -p TERM)"
        # If the runner is interrupted inside the temporary-enabled window,
        # restore the persistent bit immediately; normal cleanup below retries
        # and verifies it before returning the signal-derived failure code.
        trap 'interrupted=129; launchctl disable "$target" >/dev/null 2>&1 || true' HUP
        trap 'interrupted=130; launchctl disable "$target" >/dev/null 2>&1 || true' INT
        trap 'interrupted=143; launchctl disable "$target" >/dev/null 2>&1 || true' TERM
        traps_set=1
        if ! launchctl enable "$target" \
            || ! _svc_launchd_wait_enabled "$label" on; then
            failed=1
        fi
    fi

    if (( ! failed )); then
        if bootstrap_output="$(launchctl bootstrap "$domain" "$plist" 2>&1)"; then
            bootstrapped=1
        fi

        # bootstrap loads a definition but does not promise to start a generic
        # plist. Probe the explicit domain, then kickstart. A failed bootstrap
        # can still be a benign EEXIST race; if the same label is now loaded and
        # reaches the requested state, converge without unloading the other actor.
        loaded="$(_svc_launchd_loaded_state "$label")" || loaded=unknown
        if [[ "$loaded" == on ]]; then
            launchctl kickstart "$target" >/dev/null 2>&1 || true
            _svc_launchd_wait_active "$label" && runtime_ok=1
        fi
        (( runtime_ok )) || failed=1
    fi

    if (( restore )); then
        if ! launchctl disable "$target" \
            || ! _svc_launchd_wait_enabled "$label" off; then
            failed=1
        fi
    fi

    # Restoring disabled must not stop the loaded job; that is the orthogonal
    # running/no-boot state promised by this backend.
    if (( ! failed )) && ! _svc_launchd_wait_active "$label"; then
        failed=1
    fi
    (( interrupted )) && failed=1

    if (( failed )); then
        # Only unload when this invocation knows its bootstrap succeeded. If
        # bootstrap failed because another actor loaded the label concurrently,
        # booting it out here would turn `start` into an unexpected `stop`.
        loaded="$(_svc_launchd_loaded_state "$label")" || loaded=unknown
        if (( bootstrapped || interrupted )) && [[ "$loaded" == on ]]; then
            _svc_launchd_bootout_wait "$target" >/dev/null 2>&1 \
                || rollback_failed=1
            _svc_launchd_wait_unloaded "$label" || rollback_failed=1
        fi
        if (( restore )); then
            if ! launchctl disable "$target" >/dev/null 2>&1 \
                || ! _svc_launchd_wait_enabled "$label" off; then
                rollback_failed=1
            fi
        fi
    fi

    if (( traps_set )); then
        _svc_launchd_restore_trap "$old_hup" HUP
        _svc_launchd_restore_trap "$old_int" INT
        _svc_launchd_restore_trap "$old_term" TERM
    fi

    if (( failed )); then
        [[ -n "$bootstrap_output" ]] && printf '%s\n' "$bootstrap_output" >&2
        if (( rollback_failed )); then
            printf 'mesh services: launchd start rollback is incomplete for %s; inspect loaded/enabled state\n' \
                "$label" >&2
        fi
        _svc_launchd_failed start "$label"
        (( interrupted )) && return "$interrupted"
        return 1
    fi
    return 0
}

_svc_launchd_start_impl() {
    local label="$2" target loaded
    target="$(_svc_launchd_target "$label")"
    loaded="$(_svc_launchd_loaded_state "$label")" || {
        printf 'mesh services: launchd cannot read GUI-domain state for %s\n' "$label" >&2
        return 1
    }
    if [[ "$loaded" == on ]]; then
        launchctl kickstart "$target" || return $?
        _svc_launchd_wait_active "$label" \
            || _svc_launchd_failed start "$label"
        return $?
    fi
    _svc_launchd_start_unloaded "$label"
}

_svc_launchd_restart_impl() {
    local label="$2" target loaded old_pid
    target="$(_svc_launchd_target "$label")"
    loaded="$(_svc_launchd_loaded_state "$label")" || {
        printf 'mesh services: launchd cannot read GUI-domain state for %s\n' "$label" >&2
        return 1
    }
    if [[ "$loaded" == off ]]; then
        _svc_launchd_start_impl "$@"
        return $?
    fi
    old_pid="$(_svc_launchd_pid "$label")" || {
        printf 'mesh services: launchd cannot read the current PID for %s\n' "$label" >&2
        return 1
    }
    launchctl kickstart -k "$target" || return $?
    if [[ -n "$old_pid" ]]; then
        _svc_launchd_wait_restarted "$label" "$old_pid" \
            || _svc_launchd_failed restart "$label"
    else
        _svc_launchd_wait_active "$label" \
            || _svc_launchd_failed restart "$label"
    fi
}

svc_launchd_enable()  { _svc_launchd_with_lock _svc_launchd_enable_impl  "$@"; }
svc_launchd_disable() { _svc_launchd_with_lock _svc_launchd_disable_impl "$@"; }
svc_launchd_start()   { _svc_launchd_with_lock _svc_launchd_start_impl   "$@"; }
svc_launchd_stop()    { _svc_launchd_with_lock _svc_launchd_stop_impl    "$@"; }
svc_launchd_restart() { _svc_launchd_with_lock _svc_launchd_restart_impl "$@"; }
