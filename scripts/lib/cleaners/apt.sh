# shellcheck shell=bash
# Cleaner: apt — downloaded .deb archives + orphaned dependencies (Debian/Ubuntu,
# incl. WSL). Uses sudo. measure() reports the archive cache only; clean() also
# runs `autoremove --purge` (freed total is therefore a lower bound).
cleaner_apt_tier()    { echo 1; }
cleaner_apt_desc()    { echo "apt package archives + orphaned deps"; }
cleaner_apt_applies() { [[ "${CLEAN_OS:-}" == wsl || "${CLEAN_OS:-}" == linux ]] && command -v apt-get >/dev/null 2>&1; }
cleaner_apt_measure() { _clean_bytes_of /var/cache/apt/archives; }
cleaner_apt_clean()   {
    local freed; freed="$(_clean_bytes_of /var/cache/apt/archives)"
    sudo apt-get clean              >/dev/null 2>&1 || log_warn "clean: apt-get clean failed"
    sudo apt-get -y autoremove --purge >/dev/null 2>&1 || log_warn "clean: apt-get autoremove failed"
    printf '%s' "$freed"
}
