# shellcheck shell=bash
# Cleaner: uv — the uv (Python) package cache. Rebuilt on next resolve/install.
cleaner_uv_tier()    { echo 1; }
cleaner_uv_desc()    { echo "uv package cache"; }
cleaner_uv_applies() { _clean_paths_applies "$HOME/.cache/uv"; }
cleaner_uv_measure() { _clean_bytes_of      "$HOME/.cache/uv"; }
cleaner_uv_clean()   { _clean_paths_clean   "$HOME/.cache/uv"; }
