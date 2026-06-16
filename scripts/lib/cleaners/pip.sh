# shellcheck shell=bash
# Cleaner: pip — Python wheel/HTTP download cache. Re-downloaded on next install.
cleaner_pip_tier()    { echo 1; }
cleaner_pip_desc()    { echo "pip download cache"; }
cleaner_pip_applies() { _clean_paths_applies "$HOME/.cache/pip"; }
cleaner_pip_measure() { _clean_bytes_of      "$HOME/.cache/pip"; }
cleaner_pip_clean()   { _clean_paths_clean   "$HOME/.cache/pip"; }
