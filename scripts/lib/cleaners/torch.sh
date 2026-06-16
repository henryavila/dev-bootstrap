# shellcheck shell=bash
# Cleaner: torch — PyTorch hub/model cache. Tier-2: re-downloaded on next load.
cleaner_torch_tier()    { echo 2; }
cleaner_torch_desc()    { echo "PyTorch model/hub cache"; }
cleaner_torch_applies() { _clean_paths_applies "$HOME/.cache/torch"; }
cleaner_torch_measure() { _clean_bytes_of      "$HOME/.cache/torch"; }
cleaner_torch_clean()   { _clean_paths_clean   "$HOME/.cache/torch"; }
