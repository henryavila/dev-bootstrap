# shellcheck shell=bash
# Cleaner: nodegyp — cached Node headers/libs for native builds. Re-downloaded.
cleaner_nodegyp_tier()    { echo 1; }
cleaner_nodegyp_desc()    { echo "node-gyp header cache"; }
cleaner_nodegyp_applies() { _clean_paths_applies "$HOME/.cache/node-gyp"; }
cleaner_nodegyp_measure() { _clean_bytes_of      "$HOME/.cache/node-gyp"; }
cleaner_nodegyp_clean()   { _clean_paths_clean   "$HOME/.cache/node-gyp"; }
