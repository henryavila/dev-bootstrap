# shellcheck shell=bash
# Cleaner: brew — Homebrew stale downloads + old formula versions (mac). measure()
# is best-effort 0 (brew has no cheap byte estimate); clean() runs `brew cleanup`.
cleaner_brew_tier()    { echo 1; }
cleaner_brew_desc()    { echo "Homebrew downloads + old versions"; }
cleaner_brew_applies() { [[ "${CLEAN_OS:-}" == mac ]] && command -v brew >/dev/null 2>&1; }
cleaner_brew_measure() {
    # `brew cleanup -ns` prints "This operation would free approximately X" — the
    # unit is inconsistent to parse to bytes, so report the cache dir size instead.
    _clean_bytes_of "$(brew --cache 2>/dev/null)"
}
cleaner_brew_clean()   {
    local freed; freed="$(_clean_bytes_of "$(brew --cache 2>/dev/null)")"
    brew cleanup -s >/dev/null 2>&1 || log_warn "clean: brew cleanup failed"
    printf '%s' "$freed"
}
