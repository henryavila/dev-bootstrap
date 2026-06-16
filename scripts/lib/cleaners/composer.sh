# shellcheck shell=bash
# Cleaner: composer — PHP Composer download/VCS cache. Re-fetched on next install.
cleaner_composer_tier()    { echo 1; }
cleaner_composer_desc()    { echo "Composer download cache"; }
cleaner_composer_applies() { _clean_paths_applies "$HOME/.cache/composer"; }
cleaner_composer_measure() { _clean_bytes_of      "$HOME/.cache/composer"; }
cleaner_composer_clean()   { _clean_paths_clean   "$HOME/.cache/composer"; }
