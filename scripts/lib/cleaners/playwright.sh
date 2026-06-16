# shellcheck shell=bash
# Cleaner: playwright — downloaded browser binaries (Playwright JS + Go). Tier-2:
# re-downloaded by `playwright install` on next use.
cleaner_playwright_tier()    { echo 2; }
cleaner_playwright_desc()    { echo "Playwright browser binaries"; }
cleaner_playwright_applies() { _clean_paths_applies "$HOME/.cache/ms-playwright" "$HOME/.cache/ms-playwright-go"; }
cleaner_playwright_measure() { _clean_bytes_of      "$HOME/.cache/ms-playwright" "$HOME/.cache/ms-playwright-go"; }
cleaner_playwright_clean()   { _clean_paths_clean   "$HOME/.cache/ms-playwright" "$HOME/.cache/ms-playwright-go"; }
