# shellcheck shell=bash
# Cleaner: jetbrains — JetBrains IDE caches (indexes, etc.). Rebuilt on next open.
cleaner_jetbrains_tier()    { echo 1; }
cleaner_jetbrains_desc()    { echo "JetBrains IDE caches"; }
cleaner_jetbrains_applies() { _clean_paths_applies "$HOME/.cache/JetBrains"; }
cleaner_jetbrains_measure() { _clean_bytes_of      "$HOME/.cache/JetBrains"; }
cleaner_jetbrains_clean()   { _clean_paths_clean   "$HOME/.cache/JetBrains"; }
