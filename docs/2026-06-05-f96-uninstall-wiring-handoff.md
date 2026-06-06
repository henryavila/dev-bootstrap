# F9.6 — Uninstall wiring + per-item uninstall() + Apply fix — HANDOFF

**Date:** 2026-06-05 · **Branch:** `refactor/install-engine` · **Initiative:** `mesh-restructure-f96-tui-rebuild` (lateral expansion)

Self-contained resume doc. Read this first; it has the diagnosis, the plan, the
exact file refs, the current working-tree state, and the open design questions.

---

## TL;DR

The live TTY walk (T-501) surfaced that **deselecting a bundle in the menu does
not uninstall it**. Empirically proven on mac: deselected `web/ngrok` →
`selections.list` no longer lists it, the Summary shows "remove", **but the
binary (`/Volumes/External/homebrew/bin/ngrok` v3.39.1) and the marker
(`~/.local/state/mesh/installed/web__ngrok.env`) are both still there.**

Three stacked gaps. Fix all three:

1. **Gap 1 — Apply never runs uninstall.** `setup.sh` runs only
   `install-engine.sh`; nothing ever calls `uninstall-engine.sh`. So no
   deselect removes anything, regardless of driver.
2. **Gap 2 — drivers don't actually remove.** 49 custom scripts, **only 1**
   (`ai/install-rtk.sh`, added this session) defines `uninstall()`. The other 48
   fall into *"no uninstall() — remove manually"*. `npx` uninstall is advisory.
   `deploy` is a no-op. And the marker is dropped **unconditionally**, so the
   menu reports "removed" even when nothing was removed.
3. **Gap 3 — menu shows incoherent state.** The picker seeds its initial
   selection from the saved `selections.list` (`init.ts:41-44`), **not** from
   the install markers — so `ngrok` shows **unchecked while still installed**.
   ("estranho que no menu, ngrok aparece desmarcado" — that's this.)

---

## Goal for the next session

> "criar o uninstall de todos, forçar que sejam criados ao adicionar novo item,
> e corrigir o apply para executar o uninstall."

Three workstreams (A wires it, B makes removal real, C prevents regressions):

### Frente A — wire uninstall into the Apply (Gap 1)  ← do this FIRST

Without A, every uninstall test is vacuous (nothing runs). With A, T-501 finally
exercises the uninstall path.

- The menu already computes the remove set: `core/delta.ts:121`
  `computeDelta(prev, next)` returns `{install, remove, keep}`, used by
  `screens/SummaryConfirm.tsx`. `prev` = the saved selection / installed state.
- **Plan:** have the menu persist the removed bundles (e.g.
  `~/.config/mesh/removals.list`, one `topic/bundle` per line), and have
  `setup.sh` run `uninstall-engine.sh --selections <removals> --platform $OS`
  (+ `--non-interactive`/`--dry-run` mirroring the install args) **before** the
  install pass. Then clear/rotate the removals file.
  - `setup.sh` Apply block is **`setup.sh:282-294`** (only install-engine today).
  - `uninstall-engine.sh` already supports `--selections FILE` and does
    reverse-topo order + reverse item order + no requires_bundles closure
    (so it never auto-removes shared deps). Unit test green (6/6).
- **Alternative considered:** derive the diff in `setup.sh` from markers
  (installed bundles − new selection). More robust for the `--non-interactive`
  path (no menu, no `prev`), but needs a marker→bundle reverse map. The menu
  already has the clean delta, so prefer menu-persists-removals + a marker-diff
  fallback for the non-interactive/headless path. **DECISION NEEDED** (see below).
- After A: re-run the ngrok test — `command -v ngrok` must disappear AND the
  marker must be gone.

### Frente B — give every custom item a real uninstall() + fix the drivers (Gap 2)

**B1 — custom scripts.** 48 of 49 custom scripts lack `uninstall()`. Not all
install something removable — triage into three buckets (starter categorization
below). Note: most already have a `rollback()`, but the custom uninstall
dispatch (`uninstall-engine.sh:314-325`) calls **only `uninstall`**, never
`rollback`, and many `rollback()`s are no-ops (`ngrok` rollback is `:`). So you
cannot just fall back to `rollback()` — write explicit `uninstall()`s.

- **Installs a binary/service → needs a real `uninstall()`:**
  `ai/install-bun.sh`, `ai/install-claude.sh` (its `rollback()` already
  `rm`s `~/.local/bin/claude` — lift into `uninstall()`),
  `ai/install-moshi-hook.sh` + `ai/moshi-hook-service-{mac,wsl}.sh`,
  `databases/mssql-driver.sh`, `databases/postgresql.sh`,
  `languages/node-fnm.sh`, `languages/npm-global.sh`,
  `identity/install-gh-wsl.sh`,
  `remote-access/install-tailscale-{mac,wsl}.sh`,
  `remote-access/mosh-path-fix.sh`, `shell-terminal/install-zinit.sh`,
  `shell-terminal/atuin-login.sh` (uninstall = logout?),
  `syncthing/syncthing-service-{mac,wsl}.sh`,
  `web/extras/ngrok.sh`, `web/extras/mailpit.sh`.
  (`ai/install-rtk.sh` already done — `uninstall() { rollback; }`, sha256 guard.)
- **Config/setup → `uninstall()` reverts config OR is a documented no-op:**
  `git/gitconfig-apply.sh`, `git/gpg-signing.sh`, `git/link-lazygit-config.sh`,
  `shell-terminal/{bat-catppuccin-theme,clone-catppuccin,clone-fzf-tab,clone-p10k,clone-tpm,drift-cleanup,generate-completions,link-nvim-config,link-shipped-configs,shell-bootstrap,zinit-drift-cleanup,zsh-default-shell}.sh`,
  `remote-access/{enable-remote-login,enable-systemd-wsl,tailscale-mtu-fix-wsl}.sh`,
  `containers/post-setup-wsl.sh`, `identity/identity-setup.sh`,
  `personal/apply.sh`.
  - Policy: a no-op uninstall is allowed but MUST be explicit + commented
    (`uninstall() { :; }  # config-only: nothing to remove because …`), never
    absent — so C's gate stays meaningful.
- **Triage — probably NOT items (topic verify helpers), confirm + exempt:**
  `foundation/verify.sh`, `git/verify.sh`, `identity/verify.sh`,
  `languages/verify.sh`, `remote-access/verify.sh`, `shell-terminal/verify.sh`,
  `web/verify.sh`. (They matched the grep via `check()`; verify which are
  actually referenced as `type: custom` items vs verify hooks, and exempt the
  non-items from the L09 gate.)

**B2 — npx driver.** `scripts/lib/uninstall-handlers.sh:154` `_uninstall_npx`
is advisory-only. Align it with the install-side `npx_rollback`
(`scripts/lib/installers/npx.sh:43-47`) which already runs
`npx -y <pkg> uninstall 2>/dev/null || true`. After that, any npx item that
exposes an `uninstall` subcommand removes for real — declaratively, no per-item
custom script. **Depends on the package shipping a head-less uninstall.**
`@henryavila/atomic-skills` `uninstall` is currently interactive (@clack
confirm + scope prompt, no `--yes`) — **owner is adding a head-less flag to the
package** (out of mesh scope). `claudebar` already has `uninstall`.

**B3 — deploy driver.** `uninstall-engine.sh:313` is a deliberate no-op
("rendered files left in place"). Decide whether `deploy` items should remove
the rendered files on uninstall (needs the deploy driver to record what it
wrote). Risky (could delete user-edited config). **DECISION NEEDED.**

**B4 — marker drop.** `uninstall-engine.sh:329-331` drops the marker
unconditionally ("user intent recorded"). Reconsider: drop only on successful
removal, so the menu's "installed?" badge can't lie. At minimum, don't drop the
marker for a custom item that has no `uninstall()` (so it doesn't report
removed). **DECISION NEEDED.**

### Frente C — force uninstall() at item-creation time (gate)

- Extend **`scripts/lib/lints/L09-custom-script-contract.sh:22`**
  `required=(check install verify rollback)` → add `uninstall`. Then every new
  custom script must define `uninstall()` (a documented no-op counts). Adding an
  item without it fails `mesh lint` + the pre-commit hook.
- C and B move together: harden L09 only AFTER all 48 scripts have `uninstall()`,
  or the whole suite/pre-commit goes red. Sequence: B1 (add all) → C (harden) in
  the same PR.
- Update the custom-script contract doc + any AGENTS/CONTRIBUTING note so a human
  adding an item knows uninstall() is mandatory (human-manageable-manifest rule).

### Gap 3 — menu install-state coherence (UX)

- Root: `core/init.ts:41-44` seeds the picker from saved `selections.list`, so a
  deselected-but-still-installed bundle shows unchecked with no "still installed"
  signal. The scanner (`core/scanner.ts`) DOES know install state from markers.
- Decide the semantics: on re-run, should an installed bundle that's absent from
  `selections.list` render (a) checked (because installed), or (b) unchecked with
  an "installed → will be removed on Apply" badge? `TopicPicker.tsx` already has
  an install-state badge column (✓/◐/✗) separate from the selection box (■/☐) —
  make sure they're driven independently so "off + ✓ installed" is visible.
  **DECISION NEEDED.** Note: after Frente A makes removal real, this is the only
  thing that makes the remove intent legible before Apply.

---

## Current working tree (mesh-workstation, NOT committed)

```
 M topics/ai/manifest.yaml      AI topic: split `agent-tools` → 3 level-2 bundles
                                  (mdprobe=npm-global, atomic-skills=npx, rtk=custom)
 M topics/ai/install-rtk.sh      + uninstall() { rollback; }  (the only custom uninstall so far)
```
(An `install-atomic-skills.sh` was created then deleted — decided atomic-skills
stays `type: npx` declarative; head-less uninstall is the package's job.)

Validation already green on this tree: `validate-manifest --strict` 0/0,
menu vitest 44/44, install-engine 13/13, uninstall-engine 6/6, all lints
L01–L21 clean, shellcheck clean.

**What to do with it:** the split + rtk uninstall belong to this same effort —
keep them in the tree and fold into the uninstall-wiring PR, or commit the split
first (`feat(ai): split agent CLI tools into per-tool bundles + rtk uninstall`).
User has not authorized a commit yet (changed plan mid-session).

---

## Key file refs

| What | Where |
|---|---|
| Apply runs only install-engine (plug uninstall here) | `setup.sh:282-294` |
| Uninstall dispatch by type | `scripts/lib/uninstall-engine.sh:304-327` |
| ↳ custom: calls only `uninstall()`, warns if absent | `…:314-325` |
| ↳ deploy: no-op | `…:313` |
| ↳ marker dropped unconditionally | `…:329-331` |
| `_uninstall_npx` advisory-only (fix: B2) | `scripts/lib/uninstall-handlers.sh:154` |
| `_uninstall_npm_global` (real removal — reference) | `scripts/lib/uninstall-handlers.sh:124` |
| `npx_rollback` already runs `npx -y <pkg> uninstall` | `scripts/lib/installers/npx.sh:43-47` |
| custom driver dispatch pattern (sources script, runs verb) | `scripts/lib/installers/custom.sh` |
| L09 required-funcs array (add `uninstall`) | `scripts/lib/lints/L09-custom-script-contract.sh:22` |
| Menu remove-delta | `scripts/menu/src/core/delta.ts:121` `computeDelta` |
| Menu seeds from selections.list (Gap 3 root) | `scripts/menu/src/core/init.ts:41-44` |
| Marker→bundle install state | `scripts/menu/src/core/scanner.ts` |
| Summary shows remove set | `scripts/menu/src/screens/SummaryConfirm.tsx` |
| Selection vs install-state badges | `scripts/menu/src/screens/TopicPicker.tsx` |

---

## Acceptance criteria

- [ ] Deselect `web/ngrok` + Apply → `command -v ngrok` gone AND marker gone.
- [ ] One item per driver verified to remove **for real** (not just marker):
      `npm-global` (mdprobe), `custom+uninstall` (rtk), `brew-formula`,
      `apt` (WSL). Document the known-not-removing ones until fixed.
- [ ] All 49 custom items define `uninstall()` (real or documented no-op);
      verify helpers triaged/exempted.
- [ ] L09 hardened to require `uninstall`; adding an item without it fails
      `mesh lint` + pre-commit (add a regression test).
- [ ] `npx` items remove (after the package ships head-less uninstall + B2).
- [ ] Menu re-run renders deselected-but-installed bundles legibly (Gap 3).
- [ ] uninstall-engine + menu flow tests extended for the deselect→remove path.

## Gotchas

- bash 3.2 on macOS (no `\b` in `[[ =~ ]]`, BSD awk). See `feedback_engine_bash32_macos`.
- Drivers run under `set -o pipefail`; `tool | grep -q` broken-pipe race —
  capture-then-`[[ =~ ]]`. See `feedback_engine_pipefail_grep_q_broken_pipe` + lint L21.
- custom-item errexit is OFF inside install()/check()/verify()/uninstall()
  (sourced per-verb, invoked `|| rc=$?`) — propagate failures via an explicit
  flag, never blanket `set -e`. See `reference_engine_custom_item_errexit_disabled`.
- `--non-interactive` Apply has no menu/prev — design the removals path so it
  either no-ops removals (install-only) or diffs markers vs default selection.
- Marker `<topic>__<item>` collision (known F9.6 finding) when deriving
  bundle→item for any marker-diff fallback.

## Design decisions — RESOLVED 2026-06-05

1. **Removals source → menu-persists `removals.list`** (marker-diff fallback for
   headless deferred). ✅ DONE in Frente A (commit 46769e0).
2. **Order → uninstall BEFORE the install pass.** ✅ DONE in Frente A.
3. **deploy uninstall (B3) → permanent no-op; targeted removals via the owning
   bundle's `uninstall()` in Frente B.** deploy.sh writes user-editable config
   via managed-block merges and records no write-manifest, so auto-deleting risks
   destroying user edits. The driver stays a no-op; a deploy-rendered *mesh-owned
   standalone* artifact (e.g. the `share-project` wrapper, generated completions)
   is removed by the owning custom `uninstall()`, not the deploy driver. deploy
   keeps dropping its marker (the rendered config is intentionally left).
4. **Marker drop (B4) → only on a real removal.** ✅ DONE in Frente A (D4):
   custom w/o uninstall() (rc 75) or a failed uninstall() keeps the marker.
5. **Gap 3 UX → (b) unchecked + independent install badge, AND baseline = markers.**
   Render an installed-but-deselected bundle as ☐ (selection = intent) with a
   distinct ✓/◐ install badge (reality) + legend "installed, not selected →
   removed on Apply". Change the delta baseline `prevSelection` (wizard.tsx) from
   the saved selection to the currently-installed set (scanner/markers) so
   `computeDelta(installed, selected).remove = installed − selected`. This closes
   the original ngrok bug class: Frente A's saved-selection baseline only removes
   what was in selections.list; the marker baseline also removes items that
   drifted out of selections.list but are still installed.
6. **rtk sha256 guard → keep by default; add an explicit force override for
   user-initiated uninstall.** A drifted `~/.local/bin/rtk` may be a different
   vendor (rtk-ai/rtk vs reachingforthejack/rtk) or an external upgrade, so
   `rollback()` stays strictly guarded. `uninstall()` (explicit intent) instead
   warns actionably on drift ("differs from mesh's recorded install; not deleting
   — force with MESH_RTK_FORCE_UNINSTALL=1 or rm manually") and honors
   `MESH_RTK_FORCE_UNINSTALL=1`. With D4, not deleting keeps the marker (honest).
   So `uninstall()` is no longer just `rollback` — it adds the force path.

---

## Rollout status + resume (2026-06-05 — spun out to standalone initiative)

Now tracked as the standalone initiative `uninstall-wiring`
(`mesh-identity/.atomic-skills/initiatives/uninstall-wiring.md`) — read it for the
full directives, wave breakdown, and the wave-1 review bug-classes. **PARKED**
(user changed plan); not pushed.

**Done (13/66 custom items):** `ai/install-rtk` + `web/extras/ngrok` (Frente A,
`46769e0`) + Frente B **wave 1** (`5631853`, 11 AI+databases items).

**Method (user's choice):** one agent IMPLEMENTS `uninstall()` per script → one
adversarial agent REVIEWS it per script, via the saved Workflow recipe
`docs/2026-06-05-uninstall-fanout-workflow.js` (edit `meta.name` + `UNITS` +
labels, re-run, remediate `needs_fix` BY HAND — don't apply review blindly; the
two moshi reviewers reached opposite conclusions and the conflict needed
judgment). Wave 1 caught a HIGH data-loss bug (`install-bun` was `rm -rf`-ing all
of `~/.bun`, incl. the user's global packages).

**Resume order:** wave 2 (remote-access+identity+containers, 10) → wave 3
(shell-terminal, 21) → wave 4 (web, 7) → wave 5 (languages+foundation+git+personal+
syncthing, 15) → B2 npx driver → B3 deploy targeted removals → D5 menu (baseline=
markers + badge) → D6 rtk force → **Frente C (harden L09)** LAST (only after every
item has `uninstall()`, else the suite + pre-commit go red).
