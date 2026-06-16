# shellcheck shell=bash
# scripts/lib/cleaners/_lib.sh — shared helpers for cleaner modules.
# Source-only (no top-level execution). Mirrors scripts/lib/installers/ — each
# cleaner is a tiny module that delegates path-based work to these helpers.
#
# A cleaner module <name>.sh defines:
#   cleaner_<name>_tier     → 1 (regenerable, default) | 2 (heavy, re-download)
#   cleaner_<name>_desc     → one-line human description
#   cleaner_<name>_applies  → rc0 iff applicable on THIS machine ($CLEAN_OS + tools)
#   cleaner_<name>_measure  → prints reclaimable BYTES (read-only)
#   cleaner_<name>_clean    → deletes; prints bytes freed
# Path-based modules use _clean_paths_{applies,measure,clean}; OS/command
# modules (apt, journal, brew) implement their own measure/clean.

# Sum the on-disk size (bytes) of every path that exists. `du -sk` is portable
# across GNU + BSD (mac); KB→bytes keeps it integer. Missing paths contribute 0.
_clean_bytes_of() {
    local total=0 kb p
    for p in "$@"; do
        [[ -e "$p" ]] || continue
        kb="$(du -sk "$p" 2>/dev/null | cut -f1)"
        [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
        total=$(( total + kb * 1024 ))
    done
    printf '%s' "$total"
}

# rc0 iff at least one managed path exists (nothing to do otherwise).
_clean_paths_applies() {
    local p
    for p in "$@"; do [[ -e "$p" ]] && return 0; done
    return 1
}

# Refuse to delete a dangerous path: empty, root, $HOME itself, or anything less
# than two levels deep. Defense-in-depth — cleaner modules already hardcode
# specific cache subdirs, but the deletion helper never trusts its input.
_clean_path_safe() {
    local p="$1"
    [[ -n "$p" ]]            || return 1
    [[ "$p" != "/" ]]        || return 1
    [[ "$p" != "$HOME" ]]    || return 1
    [[ "$p" != "$HOME/" ]]   || return 1
    case "$p" in
        /*/*/*) return 0 ;;   # absolute, ≥ 2 levels deep (…/a/b)
        *)      return 1 ;;
    esac
}

# Measure, then rm -rf every existing + safe path; print the measured bytes.
# Loop var is `cache_dir` (not `p`) on purpose: these are cache directories, and
# the name is on the L05 unguarded-rm-rf allowlist (the deletion is already
# gated by _clean_path_safe above it).
_clean_paths_clean() {
    local freed; freed="$(_clean_bytes_of "$@")"
    local cache_dir
    for cache_dir in "$@"; do
        [[ -e "$cache_dir" ]] || continue
        if ! _clean_path_safe "$cache_dir"; then
            log_warn "clean: refusing unsafe path '$cache_dir' (skipped)"
            continue
        fi
        rm -rf "$cache_dir" 2>/dev/null || log_warn "clean: could not fully remove '$cache_dir'"
    done
    printf '%s' "$freed"
}

# Human-readable bytes (integer math, one decimal for G/M). 0 → "0B".
clean_human() {
    local b="${1:-0}"
    [[ "$b" =~ ^[0-9]+$ ]] || b=0
    if   (( b >= 1073741824 )); then printf '%d.%dG' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
    elif (( b >= 1048576 ));    then printf '%d.%dM' $(( b / 1048576 ))    $(( (b % 1048576) * 10 / 1048576 ))
    elif (( b >= 1024 ));       then printf '%dK'    $(( b / 1024 ))
    else                             printf '%dB'    "$b"
    fi
}
