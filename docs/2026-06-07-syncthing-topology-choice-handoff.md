# Handoff — Guided star/mesh topology choice on `mesh syncthing init-hub`

**Date:** 2026-06-07
**Initiative:** `mesh-identity/.atomic-skills/initiatives/syncthing-self-driving.md` → **T-001**
**Status of this task:** NOT STARTED (spec/handoff only — implement in a fresh session)
**Exit gate it satisfies:** G-1 of `syncthing-self-driving`.

> This file is self-contained. A fresh session should be able to implement T-001
> from this document alone. All LOGIC lands in **mesh-workstation**; `mesh-identity`
> only ever holds the filled `sync/syncthing-mesh.yaml` (data), never logic.

---

## 1. Goal (one sentence)

When a **new user** (a fork-adopter) bootstraps their mesh, let them **choose
star vs mesh through a guided `mesh syncthing init-hub` prompt** (and an optional
`mesh syncthing topology <star|mesh>` verb to switch later) — instead of having to
hand-edit `topology:`/`introducer:` in the yaml and know the trade-off from a comment.

## 2. Why (context)

`mesh-workstation` is forked/adopted by different users at different scales:

- **Small net (≤ ~6 machines)** → **mesh + introducer** is ideal: all-to-all, no
  runtime hub dependency (if the seed is offline, the other nodes still sync).
- **Dozens of machines** → **star** scales better (N connections, not N²); the hub
  must be online for two leaves to sync.

The choice **already exists and works** — it is just **not discoverable**: a forking
user only finds it by reading the template comment. Surface it at the natural
bootstrap moment (`init-hub`).

### Architectural decision (do NOT relitigate)

**The topology choice belongs in the shared identity yaml, surfaced via `init-hub`
— NOT in the installer/menu.** Reasons:

1. Topology is a **mesh-wide** property (must be identical on every node; `cmd_pair`
   reads it per-node). The installer/menu configures **one machine** → divergence risk
   (machine A "mesh", machine B "star" → introducer on for some, off for others).
2. Installer options flow to `params.env` consumed by per-machine install scripts;
   topology lives in the identity yaml — there is no option→identity-yaml bridge, and
   building one is the wrong abstraction.
3. The syncthing bundle may install before the user has an identity repo / knows their
   machine count / has minted a seed.

## 3. What ALREADY works (do not rebuild — reuse)

The mechanism for both topologies is **done + validated**. Verify before touching:

| Piece | Where | Note |
|---|---|---|
| topology + introducer honored | `scripts/lib/syncthing-rest.py` → `cmd_pair` | `use_introducer = bool(data["introducer"]) and data["topology"] == "mesh"` |
| validation of the choice | `scripts/lib/syncthing-rest.py` → `_validate_data` | rejects `topology ∉ {star,mesh}`, non-bool `introducer`, and the combo `introducer:true + star` (clear message) |
| scale-safe default for forks | `template/sync/syncthing-mesh.yaml.example` | ships `topology: star` + `introducer: false` |
| init-hub already writes the yaml | `scripts/lib/syncthing-rest.py` → `cmd_init_hub` + `_append_hub_block`; `scripts/runners/syncthing.sh` → `verb_init_hub` | `--write` appends the `hubs:` block **only when `hubs:` is empty**. Does NOT set topology/introducer today — that's the gap. |

`VALID_TOPOLOGY` and the combo rule are the contract: **always write a consistent
pair** — `mesh → introducer: true`, `star → introducer: false` — so the file never
fails `_validate_data` on the next `pair`.

## 4. The work (T-001)

### 4a. Extend `init-hub` to ask + write the topology (required)

- **Prompt (the seed machine, interactive TTY).** In `verb_init_hub`
  (`scripts/runners/syncthing.sh`), before/around the `--write`, ask one question.
  Keep it to ONE question (derive `introducer` from it — do not ask separately):

  ```
  How many machines will share this mesh?
    1) A few (≤ ~6)  → mesh   — all-to-all, resilient, no hub must stay online   [recommended for small setups]
    2) Many (dozens) → star   — scales to many machines; the hub must stay online
  ```

  → choice 1 writes `topology: mesh` + `introducer: true`; choice 2 writes
  `topology: star` + `introducer: false`.

- **Non-interactive flag.** Add `--topology <star|mesh>` to `init-hub` (and thread it
  through `cmd_init_hub`). Non-interactive + no flag → keep the template default
  (`star`/`false`) — never block a headless run.

- **Writer.** Extend `cmd_init_hub` / a small helper next to `_append_hub_block`
  (`scripts/lib/syncthing-rest.py`) to set the top-level `topology:` and `introducer:`
  lines in the yaml (same conservative `re.sub` style `_append_hub_block` uses — replace
  the existing `^topology:` / `^introducer:` lines, preserving the trailing comment or
  rewriting it). Write the **consistent pair** only. If the file already has a
  non-default topology the user is re-running on, confirm before overwriting.

- **Idempotency.** Re-running `init-hub` on an already-configured seed should be a
  no-op for topology unless `--topology` is passed (or the user confirms a change).

### 4b. Optional — `mesh syncthing topology <star|mesh>` verb (nice-to-have)

- New `verb_topology` in `scripts/runners/syncthing.sh` + dispatch in `bin/mesh`
  (`sub_syncthing` / case) + a help line. Rewrites the two yaml fields (consistent
  pair) and prints a reminder: *"run `mesh syncthing pair` on every machine to apply"*.
- Lets a user switch later without `init-hub`. If time-boxed, ship 4a first.

### 4c. Template + help polish

- `template/sync/syncthing-mesh.yaml.example`: tweak the `topology:` comment to mention
  that `mesh syncthing init-hub` asks this for you (so the hand-edit is the fallback,
  not the primary path).
- Update `bin/mesh --help` `syncthing` block if 4b adds the `topology` verb.

## 5. Files to touch

```
scripts/lib/syncthing-rest.py        # cmd_init_hub: accept + write topology/introducer (consistent pair)
scripts/runners/syncthing.sh         # verb_init_hub: the one-question prompt + --topology flag; (4b) verb_topology
bin/mesh                             # (4b) dispatch + help for the `topology` verb
template/sync/syncthing-mesh.yaml.example   # comment: init-hub asks this
tests/unit/syncthing-rest.test.sh    # tests (below)
```

## 6. Acceptance criteria (G-1)

1. `mesh syncthing init-hub` (interactive) on a fresh seed **asks star vs mesh** and
   writes **both** `topology` + `introducer` **consistently** to the yaml — no hand-edit.
2. `mesh syncthing init-hub --write --topology mesh|star` works **non-interactively**.
3. The written pair **always passes `_validate_data`** (`mesh`+`true` / `star`+`false`) —
   it never emits the rejected `introducer:true + star` combo.
4. **Default stays `star`** (scale-safe) when nothing is chosen / non-interactive / no flag.
5. Re-running without `--topology` does not silently flip an existing choice.
6. Unit tests added + green; `mesh lint` L01–L21 rc 0; `bash -n` clean.

## 7. Test plan

- **Unit (`tests/unit/syncthing-rest.test.sh`, the existing pattern):**
  - `init-hub --topology mesh` writes `topology: mesh` + `introducer: true`; re-reading
    via `read-data` parses them and **passes** validation.
  - `init-hub --topology star` writes `star` + `false`.
  - The writer never produces `introducer: true` with `star` (consistency).
  - Default path (no flag, non-interactive) leaves the template default.
- **Manual:** on a throwaway `$MESH_IDENTITY_DIR` with an empty `hubs:`, run
  `mesh syncthing init-hub --write` interactively, pick each option, inspect the yaml.

## 8. Boundaries / non-goals

- **NOT the installer/menu** (see §2 decision).
- **Admission auto-approve (`admission.tier: tailscale|token`) is OUT of scope** — it is
  the security boundary and is already roadmapped as Phase 2 in the syncthing proposal.
  It is the natural *third* leg of "self-driving" but belongs to its own task, not T-001.
- Language: CLI/menu strings are **English** (project convention: code/technical in EN,
  personal notes in pt-BR).
- Do not change `cmd_pair` / `_validate_data` semantics — only `init-hub` (+ optional verb).

## 9. Current live state of THIS repo (so you don't break it)

As of 2026-06-07 the maintainer's own mesh is **`topology: mesh` + `introducer: true`,
seed = mac (`4QEPQDH`)**, validated full-mesh across mac/ultron/crc. The repo's
`sync/syncthing-mesh.yaml` is real data — your changes must not rewrite it; test against
a throwaway `$MESH_IDENTITY_DIR`.

## 10. Sibling tasks in the same initiative (context, not this handoff)

- **T-002** — auto-reconcile `mesh syncthing pair` on `mesh update` (when the yaml
  changed) + add `syncthing pair` to the `mesh run` fan-out allowlist.
- **T-003** — DONE (2026-06-07): `pair` prints the hub admin URL in the approve prompt.
