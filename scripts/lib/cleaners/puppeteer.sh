# shellcheck shell=bash
# Cleaner: puppeteer — downloaded Chromium for Puppeteer. Tier-2: re-downloaded
# on next install/launch.
cleaner_puppeteer_tier()    { echo 2; }
cleaner_puppeteer_desc()    { echo "Puppeteer Chromium downloads"; }
cleaner_puppeteer_applies() { _clean_paths_applies "$HOME/.cache/puppeteer" "$HOME/.puppeteer-cache"; }
cleaner_puppeteer_measure() { _clean_bytes_of      "$HOME/.cache/puppeteer" "$HOME/.puppeteer-cache"; }
cleaner_puppeteer_clean()   { _clean_paths_clean   "$HOME/.cache/puppeteer" "$HOME/.puppeteer-cache"; }
