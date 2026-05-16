# Driver: custom escape hatch.
# YAML schema for custom items uses `script:` field — engine should pass ITEM_N_SCRIPT
# as the dispatch arg. Custom scripts define their own check/install/verify/rollback.
# (Engine wiring to pass $script vs $spec is Task 1.7 scope per the install-engine TODO note.)
custom_check() {
    local script="$1"
    [[ -x "$script" ]] || { echo "custom: script not executable: $script"; return 1; }
    ( . "$script"; declare -f check >/dev/null && check )
}
custom_install() {
    local script="$1"
    ( . "$script"; install )
}
custom_verify() {
    local script="$1"
    ( . "$script"; declare -f verify >/dev/null && verify || ( . "$script"; declare -f check >/dev/null && check ) )
}
custom_rollback() {
    local script="$1"
    ( . "$script"; declare -f rollback >/dev/null && rollback || true )
}
