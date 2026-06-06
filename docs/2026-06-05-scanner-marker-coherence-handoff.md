# Install-state scanner blind on v1-migrated machines — HANDOFF

**Date:** 2026-06-05 · **Branch:** `refactor/install-engine` · **Found on:** `ultron` (WSL Ubuntu, mesh node)
**Related initiative:** `mesh-identity/.atomic-skills/initiatives/uninstall-wiring.md` (same marker-coherence theme as decision **D5**)

Self-contained resume doc. Read this first.

---

## Symptom

On `ultron` (provisioned by the **v1** dev-bootstrap/dotfiles system, then the repos
switched to the v2 `refactor/install-engine` branch) the v2 setup menu marks
**practically every bundle as NOT installed**, even though the tools are physically
installed from the earlier v1 setup.

## Root cause (VALIDATED on ultron 2026-06-05 — not deduced)

The v2 menu scanner decides "installed?" **purely from per-item install markers**
and never runs the item's `check()` driver probe. A machine set up by v1 has the
tools but **zero v2 markers**, so every bundle scans `missing` → false negative.

Evidence collected on ultron:

| Probe | Result |
|---|---|
| `ls ~/.local/state/mesh/installed/*.env` | **0 markers** |
| `~/.local/state/mesh/` legacy contents | `last-applied-dev-bootstrap`, `last-applied-dotfiles`, `config.env` (← v1 artifacts; v1 never wrote v2 per-item markers) |
| `command -v` for zsh/nvim/eza/btop/fnm/node/php/docker/tailscale/syncthing/starship/atuin/rg/fzf/lazygit/delta | **all PRESENT** |
| `scripts/menu/src/core/scanner.ts:54` | `if (existsSync(markerPath(...))) installed += 1` — **marker-only, no `check()`** |

This is exactly the **drift-in** state documented in `scripts/lib/install-state.sh`
("marker absent + driver check ok → drift-in / foreign install") that the marker-only
scanner does not handle. `scanner.ts:17` itself notes: *"A live driver re-probe can
refine this later."*

> Mirror of the ngrok bug, inverted: ngrok = marker says installed when it isn't
> (false positive); this = marker absent so it says not-installed when it is (false
> negative). Both stem from the marker being the SOLE source of truth.

## Why `setup.sh` / `--dry-run` are not the answer to "just validate"

- The diagnosis above is already complete; nothing needs running to confirm it.
- A real `setup.sh` apply WOULD backfill markers as a side effect: the engine writes
  the marker when `check()` already passes (`install-engine.sh:718-728`,
  "already present, skipping" + `install_state_record`). **But it is a full apply** —
  re-deploys configs, (re)installs anything `check()` reports missing, needs sudo, and
  would be the first v2 run on ultron (the unfinished T-502 parity). Not read-only.
- `--dry-run` does NOT help: it short-circuits BEFORE `check()`
  (`install-engine.sh:592` → "[dry-run] would process …" + `continue`), so it lists
  every selected item as "would process" without probing real state.

## Fix options (for the next session)

**Option A — `mesh adopt` / engine `--adopt` (RECOMMENDED, read-only):**
A new mode that iterates items, runs the strong probe (driver verify > manifest
`check:` > driver `_check`), and writes `install_state_record` for each that PASSES —
**without** install/deploy/sudo. Read-only adoption of pre-existing installs into the
v2 marker world. The menu stays marker-only (simple, no shell-out). Reusable on any
v1-migrated machine. It is essentially the engine's existing adopt-on-check-pass
branch (`:718-728`) gated to NEVER install when the check fails. Consider wiring it
as `setup.sh --adopt` → `mesh adopt`, and optionally auto-offer it from the menu when
markers are 0 but tools are detected.

**Option B — scanner runs `check()` on marker-absent items (TS):**
Make `scanner.ts` shell out to the item's `check()` when the marker is missing.
Heavier — per-item bash + the engine env (PATH/BREW_BIN/params) the menu doesn't set
up — and abandons the scanner's "no shell-out" design. Prefer A.

**Option C — full apply:** just run `setup.sh`; markers get adopted as a side effect
of a real install/deploy run. Works, but heavy side effects + first v2 run on ultron.

## Relationship to D5 (uninstall-wiring initiative)

D5's resolution sets the menu's delta baseline to the install markers. That ASSUMES
markers reflect reality — which is false on a v1-migrated machine until adoption
exists. So **`mesh adopt` (Option A) is effectively a prerequisite for D5 to be
correct on migrated machines.** Track this finding under `uninstall-wiring`.

## Acceptance criteria

- [ ] `mesh adopt` (or `setup.sh --adopt`) on ultron writes a marker for every
      present item WITHOUT running any install/deploy and WITHOUT sudo side effects.
- [ ] After adopt, the v2 menu renders the present tools as installed (✓), not missing.
- [ ] Adopt is idempotent + safe to re-run; an absent tool gets NO marker.
- [ ] Unit/integration test: seed a tool present + no marker → adopt writes the marker;
      tool absent + no marker → no marker written.

## Key file refs

| What | Where |
|---|---|
| Scanner reads markers only (root) | `scripts/menu/src/core/scanner.ts:44-61` (+ doc note :17) |
| Marker drift-state model | `scripts/lib/install-state.sh` (header) |
| Engine adopt-on-check-pass (reuse for `--adopt`) | `scripts/lib/install-engine.sh:718-728` |
| Dry-run short-circuits before check | `scripts/lib/install-engine.sh:592` |
| Markers dir | `~/.local/state/mesh/installed/<topic>__<item>.env` |
