# Plan v2 — engine-driven detection + repair of "installed-but-broken" items

> **Status:** ✅ IMPLEMENTED 2026-06-03 (A+B+C+D, static gates green, NOT pushed — user drives the live-metal repair run per §0). · **Branch:** `refactor/install-engine` · **Initiative:** `mesh-restructure-f96-tui-rebuild` (F9.6 engine robustness). · **Reviewed by:** Codex gpt-5.5 (xhigh, read-only) 2026-06-03 — findings folded in below; decisions D-1..D-6 resolved. · Companion: `docs/2026-06-03-verify-operational-audit.md`.
>
> **Implementation note (2026-06-03):** `scripts/lib/mach-o-resolvable.sh` (new) validated on metal (broken mosh-server/-client → FAIL; @rpath `adaparse`, system fat binaries, brew formulae, scripts → PASS). brew-formula reinstall-aware install + otool verify; `_repair` verbs on brew-cask/apt/custom; valet `_valet_stack_ok` + stack-aware install + external-volume defer + `repair()`; mosh-mac manifest `check:` (executes + detects the live break) + mosh-path resolver + `repair()`; engine `--repair` (4 branches tested) + `--repair⊥--update`; `setup.sh --repair`; `mesh doctor [--fix]`. Tier-2 §D: 12 items hardened via a 24-agent harden→adversarial-verify workflow (11 ship / 1 fix — the mssql `grep -qi` case-sensitivity false-fail was caught + fixed); nginx-sites got `repair()`. Gates: bash -n all, `mesh lint` rc 0, `validate --strict` 12 manifests 0 err, full suite 44 pass / 0 regressions (26 pre-existing mac-env fails confirmed via stash baseline), shellcheck clean (pre-existing no-shebang on sourced drivers only). 4 new regression test files (25 assertions). **Pending: the live-metal repair run on mac (`mesh doctor --fix` / `setup --repair`) + WSL parity.**

## 0 · Governing principle (user directive)

**No manual fixes.** mosh + valet must be repaired *by running the installer* — never a hand-typed `brew reinstall`/`valet restart`. Making the installer detect + repair is simultaneously the fix and the **validation that the engine works**, and honours *engine implements* + *human-manageable*.

## 1 · Root cause (recap)

Engine `keep/skip` (`install-engine.sh:629`) uses **only `check()`**; stronger `verify()` runs **only post-install** (`:651`); `idempotent:` items skip both (`:614`). verify() is stronger than check() in only **8/131** items; only **12/131** checks are operational; **109/131** have a false-keep gap. Live on mac: **2 criticals** (`mosh-mac`, `valet`) + **13 verified highs**. *(All three lifecycle facts independently confirmed by Codex.)*

## 2 · Verified constraints (live mac + Codex)

1. **`brew install <formula>` on a present formula is a no-op** → repair needs **`brew reinstall`**. A stronger check alone is insufficient; the install action must become reinstall-aware.
2. **`otool -L` reveals the break statically** (lists absent `…/protobuf/lib/libprotobuf.34.1.0.dylib`) — no need to execute the binary. **But** a correct probe must resolve `@rpath`/`@loader_path`/`@executable_path` (not just skip `@*`) and tolerate universal-binary arch header lines.
3. **Homebrew read probes need offline guards.** On this host `brew list --formula -- mosh` hit the Homebrew API and exited non-zero when DNS failed (while still printing local paths). Use `HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1` + `${BREW_BIN:-brew}` for all read probes.
4. **valet `install()` does NOT currently re-run on a dead stack.** It sets `need_install=1` only when forced / `~/.config/valet` missing / `valet --version` fails — and `setup.sh:193` warms sudo first, so `valet --version` *succeeds* while nginx/dnsmasq/php-fpm are down. So strengthening `check()` alone is NOT enough; `install()` must also re-run `valet install` when an operational stack probe fails.
5. **valet `check()` must stay sudo-free** (menu scanner stubs sudo). Stack probe = TCP/DNS/socket, not the `valet` CLI. **valet DNS probe must require non-empty output** — `dscacheutil -q host ... probe.localhost` returns rc 0 with *no records*; use `dig @127.0.0.1 <name> +time=1 +tries=1 +short` and require `127.0.0.1`/`::1`.
6. **valet parks `/Volumes/External/code`** and `install()` does `mkdir -p "$CODE_DIR"` (`valet.sh:48`). If that external volume is unmounted, forcing repair can create a **phantom `/Volumes/External` on the root disk**. Repair must **defer/skip** when a configured `/Volumes/*` parked path is unmounted.
7. **`mosh-path-mac` cannot self-repair** (its install() only re-links to the same broken binary). Fixed *transitively*: `mosh-mac` (item 0 of the `mosh` bundle) reinstalls before the when-gated `mosh-path-mac`.
8. **Install markers are keyed `topic__item` only** (`install-state.sh`), with documented collision risk (`scanner.ts:19`). A repair sweep must drive off **selected-bundle context**, not bare marker filenames.
9. Engine runs **bash 3.2**; **errexit OFF inside verbs** (propagate via explicit `return 1`/flags); **brew prefix may be custom** (`/Volumes/External/homebrew` → `brew --prefix`).

## 3 · Design — four mechanisms (Codex fixes folded in)

### A · `brew-formula` driver: reinstall-aware install + operational verify

`scripts/lib/installers/brew-formula.sh`:

- **`brew_formula_install`** — reinstall when already present (a present formula reaching install() means its operational check failed ⇒ repair). **Always-on**, single attempt:
  ```sh
  brew_formula_install() {
    local brew="${BREW_BIN:-brew}"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    if "$brew" list --formula -- "$1" >/dev/null 2>&1; then
      echo "brew-formula: $1 present but install() called → reinstall (repair)" >&2
      "$brew" reinstall --formula -- "$1"
    else
      "$brew" install --formula -- "$1"
    fi
  }
  ```
- **`brew_formula_verify`** — `brew list` present **AND** every linked lib of the formula's binaries resolves, via a **standalone Mach-O resolver** (see B/D-2):
  ```sh
  brew_formula_verify() {
    local brew="${BREW_BIN:-brew}"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    "$brew" list --formula -- "$1" >/dev/null 2>&1 || return 1
    local bin ok=0
    while IFS= read -r bin; do
      ok=1
      bash "$MESH_LIB_DIR/mach-o-resolvable.sh" "$bin" || return 1
    done < <("$brew" list --formula --verbose -- "$1" 2>/dev/null | grep -E '/(s?bin)/[^/]+$')
    return 0   # ok=0 (no binaries, e.g. zsh plugins/fonts) → presence-only, no false-fail
  }
  ```
  **Coverage caveat (acknowledged):** formulae shipping no `bin`/`sbin` files (zsh-completions/-autosuggestions/-syntax-highlighting) and the **cask** font fall back to presence — that is acceptable (they don't have the native-dependency fragility); the otool layer targets binary formulae. This is exactly why operational probing stays OUT of the fast skip path (D-4).

- **New helper `scripts/lib/mach-o-resolvable.sh <binary>`** — exits 0 iff every load-command path resolves. Must:
  - parse `otool -L` (skip the first line and any arch banner; take field 1);
  - **resolve `@loader_path`/`@executable_path`** relative to the binary's dir;
  - **resolve `@rpath`** against the binary's `LC_RPATH` entries (`otool -l` → `LC_RPATH`/`path`), each itself possibly `@loader_path`-relative;
  - accept `/usr/lib/*` and `/System/*` as present (dyld shared cache — never on disk);
  - return non-zero with a diagnostic on the first missing path.

### B · Targeted operational detection for the 2 live criticals (so normal `mesh setup` self-heals)

- **`mosh-mac`** (`topics/remote-access/manifest.yaml`): operational `check:` override calling the **standalone helper** (not an inline one-liner, not a driver function — `bash -c` can't see those):
  ```yaml
  - name: mosh-mac
    type: brew-formula
    spec: mosh
    platforms: [mac]
    check: 'HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 "${BREW_BIN:-brew}" list --formula -- mosh >/dev/null 2>&1 && bash "$MESH_LIB_DIR/mach-o-resolvable.sh" "$(${BREW_BIN:-brew} --prefix)/bin/mosh-server"'
  ```
  Broken → check fails → reinstall-aware install → `brew reinstall mosh` → relinked → verify (otool) passes.
- **`valet`** (`topics/web/mac/valet.sh`): factor a sudo-free `_valet_stack_ok` and use it in BOTH `check()` and `install()`:
  ```sh
  _valet_stack_ok() {   # sudo-free; all three daemons serving
    (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null || return 1            # nginx
    local a; a="$(dig @127.0.0.1 probe.localhost +time=1 +tries=1 +short 2>/dev/null)"
    [[ "$a" == 127.0.0.1 || "$a" == ::1 ]] || return 1                 # dnsmasq
    [[ -e "$HOME/.config/valet/valet.sock" ]] || return 1             # php-fpm
  }
  # check(): existing markers AND _valet_stack_ok  (UNLESS a /Volumes/* parked path is unmounted → defer; see C/D-3)
  # install(): set need_install=1 when ! _valet_stack_ok (in addition to the existing conditions),
  #            and GUARD `mkdir -p "$CODE_DIR"` + park behind a mount check for /Volumes/* paths.
  ```
- **`mosh-path-mac`** (`mosh-path-fix.sh`): replace `[[ -x /usr/local/bin/mosh-server ]]` in `check()`/`verify()` with `bash "$MESH_LIB_DIR/mach-o-resolvable.sh" /usr/local/bin/mosh-server`. Reports broken; repaired transitively by `mosh-mac` reinstalling first.

### C · General precise verify+repair pass — `mesh doctor --fix` (durable Tier-1)

Default = **explicit `mesh doctor --fix`** (NOT auto-run by `mesh update`; optional `setup --repair`). Semantics (Codex §7):
- **Selection source:** drive off **selected/installed bundles in their bundle context**, not raw `topic__item` markers (collision-safe). Reuse the engine's selection + topo machinery; for each item run its **strong** probe (`_verify`/`verify()`), and on fail run a **repair** then re-probe (cap **one** attempt/item/run; persistent fail → rc 67 with a clear message).
- **Repair action per type:** `brew-formula`/`brew-cask` → `brew reinstall`; `custom` → re-run `install()` **only if it declares a `repair()` or is on an idempotent-safe allowlist** (don't blindly re-run destructive installers); `apt` → `apt-get install --reinstall`; `npm-global` → `npm install -g`; `npx`/`deploy` → re-run install.
- **Mutual exclusion:** `--repair` and `--update` are mutually exclusive (the `--update` branch exits before the normal lifecycle at `install-engine.sh:581`); reject `--repair --update` with an arg error.
- `mesh doctor` today is deploy-drift only (`doctor.sh`); this adds the missing engine-wide item verifier. `topics/*/verify.sh` (only `command -v`) stay as-is / can feed this later.

### D · The 13 verified highs — per-class `check()`/`verify()` hardening (Tier 2)

- **clone/symlink `filesystem`** (`code-server`, `tpm-clone`, `iterm2-font-config`, web `mkcert`-wsl, `nginx-sites`, `mosh-path-mac`): require `[[ -e "$dst" ]]` (drop the dangling-symlink-passes branch) **+** a content sentinel (repo `HEAD` / key file); keep first-writer-wins.
- **service daemon-up≠functional** (`rtk`, `moshi-hook-*-service`): gate on functional state (`_is_running && _is_paired`); prefer launchctl/service state over loose `pgrep -f`.
- **presence/marker** (`mssql-driver`, `core-wsl`, web `packages`, `tailscale-mtu-wsl`): add the functional probe install() implies (e.g. mssql `odbcinst -q -d`; `return 1` for any configured PHP version missing the ext — check()/install() currently disagree on scope).

## 4 · Validation protocol (THROUGH the installer — no manual repair)

1. Pre-state (read-only, captured): `brew list mosh`=0 + `mosh-server --version`=dyld abort; `curl :80`=refused.
2. **mosh:** run engine for `remote-access/mosh` → operational `check:` fails → reinstall-aware install → `brew reinstall mosh` → `brew_formula_verify` passes; confirm `mosh-server --version` no longer aborts.
3. **mosh-path:** same run, check green (helper resolves), symlink valid.
4. **valet:** run `web/valet` → strengthened `check()` fails (stack down) → `install()` re-runs `valet install` (now via `_valet_stack_ok`) → confirm `curl -I http://localhost/` serves.
5. **idempotent re-run:** both bundles → check passes → skip, rc 0.
6. **general pass:** `mesh doctor --fix` sweeps, repairs the same, exits 0 on a healthy tree; `--repair --update` rejected.
7. **external-volume:** with `/Volumes/External` unmounted, repair **defers** (no `valet install`, no `/Volumes/External` phantom created).
8. Gates: engine unit/integration tests, `mesh lint`, `validate --strict`, shellcheck — all green.

## 5 · Risks & design-principle compliance

errexit-OFF → explicit `return 1`/flags. sudo-free `check()` preserved. custom brew prefix via `brew --prefix`. `brew reinstall` = repair, not uninstall (compliant). repair ≠ T-600 update (kept distinct + mutually exclusive). operational probes only in verify/repair → no fast-path cost. all repairs idempotent + capped at 1 attempt/run + re-probe to avoid loops. custom repair gated by `repair()`/allowlist to avoid re-running destructive installers.

## 6 · Decisions (RESOLVED, per Codex)

- **D-1** → Explicit `mesh doctor --fix` by default + targeted normal-setup self-heal for the 2 criticals only; optional `setup --repair`; **no** auto-sweep in `mesh update`.
- **D-2** → Standalone reusable helper (`mach-o-resolvable.sh`) via `$MESH_LIB_DIR`; defer new manifest fields (`verify_binary`/`smoke`) until more formulae need per-binary metadata.
- **D-3** → **Defer/skip** valet repair when a configured `/Volumes/*` parked path is unmounted; report it in doctor (don't fail, don't `mkdir` a phantom).
- **D-4** → Keep global brew operational probes OUT of the fast skip path; exception only for targeted criticals (mosh/valet).
- **D-5** → `otool` dylib-existence as default static probe, but implement `@rpath/@loader_path/@executable_path` resolution before treating it as generic; smoke overrides later.
- **D-6** → reinstall-when-present **always-on** in the brew driver, but only reachable via a deliberate failed operational check/repair, **one** attempt, clear rc 67 on persistent failure.

## 7 · Must-fix checklist + regression tests (before/with implementation)

**Must-fix (from Codex):**
- [x] mosh detection = tested standalone `mach-o-resolvable.sh` (real file-existence + @rpath/@loader_path/@executable_path resolution), called from manifest `check:`.
- [x] valet `install()` re-runs `valet install` when `_valet_stack_ok` fails (not just on `valet --version`).
- [x] valet DNS probe via `dig @127.0.0.1 +short` requiring `127.0.0.1`/`::1`; external-volume **defer** + guard `mkdir`/park.
- [x] Homebrew offline env guards + `${BREW_BIN:-brew}` on all read probes (brew-formula + brew-cask).
- [x] repair-mode semantics: selected-bundle selection source, marker-collision-safe (marker-gated), custom `repair()` opt-in (rc 75 = no-safe-repair → reported, not blind re-run), `--repair`⊥`--update`.

**Regression tests:** (all green — `tests/integration/engine-repair.test.sh`, `tests/unit/{mach-o-resolvable,brew-formula-repair,valet-stack-probe}.test.sh`)
- [x] skip-path-bypasses-verify (engine integration).
- [x] `brew_formula_install` reinstalls when present, plain-installs when absent.
- [x] `mach-o-resolvable.sh`: detects a missing absolute dylib; passes a healthy binary; resolves @rpath/@loader_path.
- [x] valet dead-stack detection + external-volume defer (no phantom dir).
- [x] `--repair`⊥`--update`, repaired/unrepairable(rc67)/healthy(rc0)/no-marker-skip branches.

## 8 · Out of scope

38 MEDIUM / 16 LOW (presence≈operational, wsl-distro) — documented, unchanged. WSL items' live validation — crc/ultron parity pass later. Menu/TUI unchanged. Nice-to-have (later): schema-backed `verify_binary`/`smoke`; cask/apt/npm repair verification; cleanup of stale menu `valet-check` tests referencing an absent shell-out scanner path.

## 9 · Codex review log

Full review: `.ai/codex-plan-review.md` (gpt-5.5 xhigh, read-only, exit 0). Confirmed the 3 lifecycle facts; raised 7 findings (2 critical: valet-repair-not-triggered, mosh-inline-check-wrong) — all folded into §2-§7 above. Review prompt: `.ai/codex-review-prompt.txt`.
