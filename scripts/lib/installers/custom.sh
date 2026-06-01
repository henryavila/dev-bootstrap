# Driver: custom escape hatch.
# YAML schema for custom items uses `script:` field — engine should pass ITEM_N_SCRIPT
# as the dispatch arg. Custom scripts define their own check/install/verify/rollback.
# (Engine wiring to pass $script vs $spec is Task 1.7 scope per the install-engine TODO note.)
custom_check() {
    local script="$1"
    # Custom scripts are SOURCED (`. "$script"`) by every verb below, never
    # executed — so they need to be readable, not executable. The previous
    # `-x` gate made any custom script missing the exec bit fail check()
    # unconditionally (regardless of its real state), forcing install() to
    # re-run on every pass and silently breaking idempotency-respect.
    [[ -r "$script" ]] || { echo "custom: script not readable: $script"; return 1; }
    ( . "$script"; declare -f check >/dev/null && check )
}
custom_install() {
    # CP4 A2-F-007: require the script to define an install() function.
    # Otherwise `install` resolves through PATH to /usr/bin/install (system
    # file-copy tool), which is a silent-wrong-program hazard. Hard-fail
    # the contract instead.
    local script="$1"
    (
        . "$script"
        if ! declare -f install >/dev/null; then
            echo "custom: $script does not define install() — contract violation" >&2
            exit 64
        fi
        install
    )
}
custom_verify() {
    # If the script defines verify(), use ITS return code authoritatively.
    # Fall back to check() ONLY when verify() is undefined. Codex review
    # 2026-05-19 (A-F002): the previous `verify || check` allowed a failed
    # verify to silently succeed when the weaker check() still passed,
    # masking real verification failures.
    # CP4 A2-F-008: require ONE of verify/check — defaulting to success
    # when neither exists hides custom scripts that forgot to declare a
    # verifier. Custom scripts MUST opt in to verification.
    local script="$1"
    (
        . "$script"
        if declare -f verify >/dev/null; then
            verify
        elif declare -f check >/dev/null; then
            check
        else
            echo "custom: $script defines neither verify() nor check() — cannot validate install" >&2
            exit 64
        fi
    )
}
# Version-aware update (T-600): run the script's own update() if it defines one
# (e.g. a tool with a self-update subcommand). Absent → no-op; the engine logs
# "no updater" and the custom installer stays untouched on `mesh update`.
custom_update() {
    local script="$1"
    [[ -r "$script" ]] || { echo "custom: script not readable: $script" >&2; return 1; }
    (
        . "$script"
        if declare -f update >/dev/null; then
            update
        else
            echo "custom: $script defines no update() — skipping" >&2
        fi
    )
}
custom_rollback() {
    # CP4 A2-F-008: surface rollback failure rather than swallowing it
    # with `|| true`. If rollback explicitly fails, the caller (engine)
    # should know — partial state may remain.
    local script="$1"
    (
        . "$script"
        if declare -f rollback >/dev/null; then
            rollback
        fi
    )
}
