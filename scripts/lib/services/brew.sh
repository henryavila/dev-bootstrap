# shellcheck shell=bash
# scripts/lib/services/brew.sh — Homebrew (`brew services`) backend.
#
# brew services is NON-ORTHOGONAL — it cannot set the two bits independently,
# so svc_brew_orthogonal returns 1 and svc_status emits orthogonal=no (codex
# F-001). The verb→`brew services` mapping (the honest coarse model):
#   start   → `brew services run`     : runs now, NO login registration (active only)
#   enable  → `brew services start`   : runs now AND registers at login (BOTH bits)
#   stop    → `brew services stop`    : stops AND unregisters (BOTH bits)
#   disable → `brew services stop`    : brew has no stop-less unregister (BOTH bits)
#   restart → `brew services restart` : re-runs (active)
#
# Descriptor scope is empty for brew; target = the formula. Sourced; no set -e.

svc_brew_orthogonal() { return 1; }

svc_brew_installed() { brew list --formula --versions "$2" >/dev/null 2>&1; }

svc_brew_start()   { brew services run     "$2"; }
svc_brew_enable()  { brew services start   "$2"; }
svc_brew_stop()    { brew services stop    "$2"; }
svc_brew_disable() { brew services stop    "$2"; }
svc_brew_restart() { brew services restart "$2"; }

svc_brew_status() {
    local formula="$2" state active enabled
    state="$(brew services list 2>/dev/null | awk -v f="$formula" '$1==f {print $2; exit}')"
    case "$state" in
        started|scheduled) active=on;  enabled=on ;;
        stopped|none|"")   active=off; enabled=off ;;
        error)             active=off; enabled=off ;;
        *)                 active=unknown; enabled=unknown ;;
    esac
    printf 'active=%s\nenabled=%s\northogonal=no\n' "$active" "$enabled"
}
