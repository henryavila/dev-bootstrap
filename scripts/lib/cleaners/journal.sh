# shellcheck shell=bash
# Cleaner: journal — systemd journal logs. Vacuums to 200M (keeps recent logs).
# Uses sudo. measure() reads the on-disk journal dirs (best-effort).
cleaner_journal_tier()    { echo 1; }
cleaner_journal_desc()    { echo "systemd journal logs (vacuum to 200M)"; }
cleaner_journal_applies() { command -v journalctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
cleaner_journal_measure() { _clean_bytes_of /var/log/journal /run/log/journal; }
cleaner_journal_clean()   {
    local before; before="$(_clean_bytes_of /var/log/journal /run/log/journal)"
    local after
    sudo journalctl --vacuum-size=200M >/dev/null 2>&1 || log_warn "clean: journalctl vacuum failed"
    after="$(_clean_bytes_of /var/log/journal /run/log/journal)"
    if (( before > after )); then printf '%s' $(( before - after )); else printf '0'; fi
}
