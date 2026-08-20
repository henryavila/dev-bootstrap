# Design: soft_fail for external-download install items

**Date:** 2026-08-20  
**Status:** approved  
**Repo:** mesh-workstation  
**Branch:** `feat/soft-fail-external-downloads`

## Problem

WSL items that fetch GitHub release assets (`rust-bins-wsl`, `lazygit-wsl`,
`git-delta-wsl`, …) can stall on corporate networks. The install engine treats
any item failure as fatal (`exit 67` / non-zero), so one hung CDN download
blocks the rest of bootstrap. `curl -s` also leaves the TUI/log looking idle.

## Decision

Add an explicit per-item manifest flag:

```yaml
soft_fail: true
```

Semantics when `soft_fail: true`:

1. **Wall-clock cap** — wrap the item install/repair path with
   `timeout` (default 300s, overridable via `MESH_SOFT_FAIL_TIMEOUT`).
2. **Non-fatal failure** — install failure, post-verify failure, repair
   failure, or timeout → `log_warn` + `followup manual "…"` + item subshell
   exits **0** so the bundle and run continue.
3. **No install marker** on soft failure (item remains absent for a later
   retry / `mesh doctor --fix`).
4. Hard-fail items keep today’s abort-the-run behaviour.

## Scope of flags (initial)

Mark known GitHub-release / CDN custom items:

- `shell-terminal`: `rust-bins-wsl`, `lazygit-wsl`, `git-delta-wsl`, `starship-wsl`
- `ai`: `rtk`
- `web`: `mkcert` (WSL custom), `mailpit`

Also tighten download timeouts + progress logs in `install-rust-bins.sh`,
and add bounded `curl` to `install-lazygit.sh` / `install-delta.sh` (those
were unbounded).

## Non-goals

- Do not soft-fail all items by default.
- Do not change membership / `--no-mesh` filtering.
- Do not auto-infer soft_fail from `type:` alone (explicit flag only).

## Verification

- Unit: yaml-parse emits `*_SOFT_FAIL=1`; unknown without the key stays unset.
- Unit: install-engine continues past a soft_fail item that returns non-zero
  or times out; a following item still runs; followup file gets an entry;
  hard-fail neighbour still aborts.
- Focused suites green; `mesh lint` on touched paths.

## Follow-up 2026-08-20 — loop breaker (CRC)

**Root cause:** `_run_bounded` killed only the top PID, leaving grandchild
`curl`/subshell orphans that kept resolving/downloading dust tags after the
item should have moved on. Nested `gh_api`×`curl --retry`×3 binaries amplified
the “loop on dust tag” appearance on corporate networks.

**Fix:** process-group kill (`set -m` + `kill -$pgid` when PGID==pid, else
tree reap); default soft_fail budget 300s (rust-bins worst case ~261s);
rust-bins one-shot curl (no `--retry`), `MESH_GH_API_ATTEMPTS=2`,
per-binary circuit breaker that refuses a second resolve/download.
