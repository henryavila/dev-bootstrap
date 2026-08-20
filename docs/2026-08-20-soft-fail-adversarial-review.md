## Resolution

**Fixed on tip `f4b0900` (PR #38)** relative to this finding snapshot. Historical
`Status: open` lines below are the pre-fix review record; do **not** treat them
as current hang-path truth. Live contract: default soft_fail budget **300s**,
REPAIR via `_run_bounded`, process-group/tree reap, rust-bins one-shot + TTL
breaker + selective rollback, cooldown stamps, bounded curl on CDN soft_fail
installers. Remaining product residual: mkcert soft_fail may leave degraded TLS
siblings (Issue 8 — accepted for bootstrap-continue).

## Summary

The apply-path soft_fail continue + outer `) ||` handler does keep bootstrap moving past immediate item failures, and on Linux `set -m` + `kill -$pid` does reap the hang-test grandchild. The loop-breaker story is still incomplete: `--repair` never enters `_run_bounded`, the default 90s budget is smaller than rust-bins’ own sequential curl budget (so timeout + rollback can wipe successful sibling binaries), several soft_fail installers still use unbounded `curl`, and the rust-bins “circuit breaker” resets on every `custom_install` re-source so it does not police the failure mode the design claims.

## Issues

### Issue 1 -- Severity: bug
- File: /home/henry/mesh-workstation/scripts/lib/install-engine.sh:1016
- Description: The dedicated `REPAIR_MODE` / `mesh doctor --fix` path still calls `"${prefix}_repair"` / `"${prefix}_install"` directly with no `_run_bounded` wall-clock. Soft_fail items can hang the entire repair sweep on a stuck CDN even though apply-time `_repair_once` (lines 1174–1179) is wrapped. Design §Decision (“wrap the item install/repair path”) and the CRC follow-up claim are false for the mode that exists specifically to fix broken installs.
- Suggestion: Route the REPAIR_MODE repair/install invocation through `_run_bounded` (or share `_repair_once`), map rc 124 into the existing repair-fail recording path, and add a unit test that a soft_fail repair hang continues the sweep.
- Status: fixed (PR #38) — see Resolution

### Issue 2 -- Severity: bug
- File: /home/henry/mesh-workstation/scripts/lib/install-engine.sh:793
- Description: Default `MESH_SOFT_FAIL_TIMEOUT=90` is not safe for `rust-bins-wsl`. Each binary allows API up to 2×20s (+ backoff sleep) plus `curl --max-time 45` (`install-rust-bins.sh:16–19,108–125`). Worst case per binary ≈87s; three sequential binaries ≈261s. A merely slow network that respects curl caps still gets SIGTERM mid-binary-2/3; engine then runs `custom_rollback` which deletes dust/xh/procs that already installed (`install-rust-bins.sh:138–142`), producing “timed out” soft_fail after destroying partial success.
- Suggestion: Raise the default budget above 3×(API+download) (or make rust-bins a single bounded download phase with a shared deadline), and/or stop rolling back already-verified sibling binaries on aggregate failure. Add a test where binary1 succeeds, binary2 hits the wall clock, and assert binary1 remains.
- Status: fixed (PR #38) — see Resolution

### Issue 3 -- Severity: bug
- File: /home/henry/mesh-workstation/topics/shell-terminal/wsl/install-starship.sh:3
- Description: Several newly soft_fail-marked installers never got download caps; they only rely on the 90s process-group watchdog. `starship` is `curl -fsSL … | sh` with no `--connect-timeout`/`--max-time`. Same gap: `topics/web/wsl/mkcert.sh:43`, `topics/web/scripts/install-mailpit.sh:54`, `topics/ai/install-rtk.sh:120–124`. On a half-open proxy each burns the full soft_fail budget; rtk/mailpit also run on macOS (not just WSL), where this PR’s PGID kill behavior is untested. Design said to tighten timeouts beyond rust-bins/lazygit/delta, but the other soft_fail flags were added without matching curl bounds.
- Suggestion: Add the same `--connect-timeout`/`--max-time` (and avoid `curl|sh` where possible) to every soft_fail installer; fail closed before the wall clock whenever curl can.
- Status: fixed (PR #38) — see Resolution

### Issue 4 -- Severity: bug
- File: /home/henry/mesh-workstation/scripts/lib/install-engine.sh:794
- Description: `_run_bounded` does `set -m` with no check that monitor mode took effect or that the background job’s PGID equals `cmd_pid`. Empirically on Linux it works (including under `| tee`, matching `setup.sh`). If `set -m` is a no-op or unavailable, the fallback `kill -TERM "$cmd_pid"` is exactly the top-PID-only kill that left CRC curl orphans. Under engine `set -e`, a hard `set -m` failure aborts the item into the outer soft_fail handler (bootstrap continues) without reaping grandchildren. No test asserts `pgid==pid` after spawn.
- Suggestion: After `"$@" &`, read `pgid` and if it differs from `cmd_pid`, kill the tree another way (e.g. `setsid` wrapper, explicit `kill` of known children, or `timeout --foreground` where GNU timeout exists). Treat failed `set -m` as an error path that still best-effort reaps.
- Status: fixed (PR #38) — see Resolution

### Issue 5 -- Severity: suggestion
- File: /home/henry/mesh-workstation/topics/shell-terminal/wsl/install-rust-bins.sh:25
- Description: The circuit breaker does not survive the real engine nesting. `custom_install` always runs `( . "$script"; install )` (`scripts/lib/installers/custom.sh:23–31`), so `_RB_TRIED_*` start at 0 on every call; `repair()` even resets them (`install-rust-bins.sh:130–135`). Nothing in `install()` re-enters `_install_dust` after failure—the CRC “dust loop” was `gh_api` retries × `curl --retry`, which one-shot curl + `MESH_GH_API_ATTEMPTS=2` address. Guards do not prevent loops across repair(), engine re-entry, or custom_install’s inner subshell re-source.
- Suggestion: Drop or re-document the breaker as in-process only; if cross-attempt suppression is required, persist intent outside the sourced script (marker/sidecar) rather than shell globals that re-source clears.
- Status: fixed (PR #38) — see Resolution

### Issue 6 -- Severity: suggestion
- File: /home/henry/mesh-workstation/tests/unit/rust-bins-fail-fast.test.sh:66
- Description: The fail-fast test is largely tautological relative to the claimed hang. It sources the script once, calls `_install_dust` twice in the same shell, then pre-sets `_RB_TRIED_*=1` before `install()`. That never mutates the orphan-grandchild / `custom_install` re-source / engine re-entry failure mode. The useful assertions are only “no `--retry`” and “one curl invocation on first failure.” The engine hang test (`install-engine.test.sh` soft_fail timeout) does exercise PGID kill with a sleep grandchild—but not curl/`gh_api` retry orphans, and not `--repair`.
- Suggestion: Add a test that runs through `custom_install` twice (fresh inner subshell) and/or drives a fake curl child that ignores SIGTERM briefly; add a repair-mode hang test once Issue 1 is fixed.
- Status: fixed (PR #38) — see Resolution

### Issue 7 -- Severity: suggestion
- File: /home/henry/mesh-workstation/scripts/lib/install-engine.sh:775
- Description: Soft failure deliberately writes no install marker, so the next bootstrap retries every soft_fail miss for up to `MESH_SOFT_FAIL_TIMEOUT` each. Seven flagged items (rtk, starship, lazygit, delta, rust-bins, mkcert, mailpit) can stall on the order of 7×90s on a persistently broken corporate network every run; followup text does not shorten the next attempt. `followup` also no-ops persistence when `MESH_FOLLOWUP_FILE` is unset (inline warn only)—fine for direct engine invokes, but easy to miss in non-setup entrypoints.
- Suggestion: Record a short-lived soft-fail stamp (mtime/cooldown) skipped unless `--repair`/forced retry; always ensure setup sets `MESH_FOLLOWUP_FILE` before engine invoke (verify all entrypoints).
- Status: fixed (PR #38) — see Resolution

### Issue 8 -- Severity: suggestion
- File: /home/henry/mesh-workstation/topics/web/wsl/mkcert.sh:147
- Description: `mkcert` is soft_fail with a no-op `rollback` (`:`). A timeout after binary install / mid-`mkcert -install` can leave a half-trusted CA while the same WSL nginx bundle continues to `serve-config` / `nginx-sites` / `service-convergence`. That is security-adjacent degraded HTTPS rather than a clean skip. Design explicitly included mkcert, but soft_fail + empty rollback + continuing siblings is a sharper footgun than CDN CLI tools.
- Suggestion: Prefer hard-fail or bundle-level gating for trust-root install; if soft_fail stays, fail closed on sibling TLS items when mkcert did not verify, and tighten mkcert’s own curl bound (Issue 3).
- Status: fixed (PR #38) — see Resolution

### Issue 9 -- Severity: nit
- File: /home/henry/mesh-workstation/scripts/lib/github-api.sh:28
- Description: `for ((attempt=1; attempt<=max_attempts; attempt++))` is bash-3.2-safe (L15 only flags mapfile/readarray/declare -A), so the macOS `for ((` worry does not land. Residual risk is non-numeric `MESH_GH_API_ATTEMPTS` tripping `[[ -ge ]]` under `set -e` when sourced into engine item subshells—narrow edge case.
- Suggestion: Prefer the previous `for attempt in $(seq …)` style or validate with a digit regex before the arithmetic comparison.
- Status: fixed (PR #38) — see Resolution
