#!/usr/bin/env bash
# Unit tests for scripts/lib/conditions.sh (named `when:` resolver, T-201).
# Bash 3.2 compatible. Uses MESH_COND_OS / MESH_WSL_CORPORATE test hooks so the
# verdicts are deterministic regardless of the host running the suite.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

pass=0; fail=0; fails=""
ok()  { pass=$((pass + 1)); }
no()  { fail=$((fail + 1)); fails="$fails\n  FAIL: $1"; }
# check <label> <cmd...> — expects cmd to succeed (rc 0).
check()   { local lbl="$1"; shift; if "$@"; then ok; else no "$lbl (expected rc 0)"; fi; }
checkno() { local lbl="$1"; shift; if "$@"; then no "$lbl (expected rc non-0)"; else ok; fi; }

. "$WS/scripts/lib/conditions.sh"

# --- introspection contract ---
[ "$(cond_list | wc -l | tr -d ' ')" = 6 ] && ok || no "cond_list should list 6 conditions"
check   "is_known/brew_prefix_custom"      cond_is_known brew_prefix_custom
check   "is_known/php_installed"           cond_is_known php_installed
checkno "is_known/bogus"                   cond_is_known bogus

# Every name from cond_list must be known + dispatchable (no unknown-condition rc 2).
while IFS= read -r c; do
    cond_is_known "$c" || no "cond_list emitted unknown name '$c'"
    cond_eval "$c" >/dev/null 2>&1; rc=$?
    [ "$rc" = 2 ] && no "cond_eval '$c' returned unknown-condition rc 2"
done < <(cond_list)
ok  # reaching here without a hard error is a pass marker

# --- dispatcher rejects unknown ---
cond_eval definitely-not-a-condition >/dev/null 2>&1
[ $? = 2 ] && ok || no "cond_eval unknown should rc 2"

# --- OS gating via test hook ---
# wsl_corporate is false off-WSL even with the opt-in set...
( export MESH_COND_OS=mac MESH_WSL_CORPORATE=1; cond_wsl_corporate ) && no "wsl_corporate true on mac" || ok
# ...and true on WSL with the explicit opt-in.
( export MESH_COND_OS=wsl MESH_WSL_CORPORATE=1; cond_wsl_corporate ) && ok || no "wsl_corporate should be true on WSL with opt-in"

# brew_prefix_custom is mac-only.
( export MESH_COND_OS=wsl; cond_brew_prefix_custom ) && no "brew_prefix_custom true on wsl" || ok

# tailscale authkey purely env-driven.
( unset TAILSCALE_AUTHKEY; cond_tailscale_authkey_present ) && no "authkey true when unset" || ok
( export TAILSCALE_AUTHKEY=k; cond_tailscale_authkey_present ) && ok || no "authkey false when set"

total=$((pass + fail))
echo "conditions tests: $pass / $total passed"
if [ $fail -gt 0 ]; then printf '%b\n' "$fails"; exit 1; fi
echo "OK"
