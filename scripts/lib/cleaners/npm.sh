# shellcheck shell=bash
# Cleaner: npm — content-addressable cache + npx install cache. Regenerated on
# next install. Preserves _logs (diagnostics, not a cache).
cleaner_npm_tier()    { echo 1; }
cleaner_npm_desc()    { echo "npm cache (_cacache + _npx)"; }
cleaner_npm_applies() { _clean_paths_applies "$HOME/.npm/_cacache" "$HOME/.npm/_npx"; }
cleaner_npm_measure() { _clean_bytes_of      "$HOME/.npm/_cacache" "$HOME/.npm/_npx"; }
cleaner_npm_clean()   { _clean_paths_clean   "$HOME/.npm/_cacache" "$HOME/.npm/_npx"; }
