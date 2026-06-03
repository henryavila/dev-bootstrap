# HANDOFF — implement all custom-script audit corrections

> **Status:** review DONE (this session); implementation PENDING (next session).
> **Repo:** all fixes are in `mesh-workstation` (this repo). Branch `refactor/install-engine` (F9.6).
> **Tracked by:** initiative `mesh-restructure-f96-tui-rebuild` (in `mesh-identity/.atomic-skills/`).

## 0 · What this is

An adversarial audit of **all 73 custom item scripts** under `topics/*/` produced **43 findings**
(1 critical, 12 high, 11 medium, 19 low; 38 files clean). **Every high/critical was
adversarially re-verified and confirmed real.** This doc is the self-contained plan to fix them
all in a fresh session — no need to re-run the audit.

Audit workflow run id: `wmuxx0t7p` (raw JSON was at
`/private/tmp/.../tasks/wmuxx0t7p.output`, ephemeral — the full findings are embedded in §5 below).

## 1 · Context from this session (read first)

Prior work this session, on branch `refactor/install-engine` (all committed in mesh-workstation):
- `ebc8686` feat(menu): apply-time required-option gate (Option A) — `incompleteRequired()` in
  `scripts/menu/src/core/form-spec.ts`, wired in `wizard.tsx` (`tryContinue`).
- `adddf0d` feat(menu): IdentityOnboarding screen + `personal/repo` required + owner/name clone fix.
- `8874995` fix(menu): quit aborts setup (EXIT_CANCEL=130) instead of installing defaults.
- **`3c70a15` fix(engine): put Homebrew's bin on PATH for item subshells** — THIS IS THE SHAPE TO
  REUSE for Wave 1. See `scripts/lib/install-engine.sh` ~line 134-150 (the `if [[ "$PLATFORM" ==
  "mac" ]]` brew block) and the regression test `tests/integration/engine-brew-path.test.sh`.

**Engine flow facts (load-bearing for every fix):**
- Custom driver `scripts/lib/installers/custom.sh` SOURCES each script in a FRESH subshell per verb:
  `( . "$script"; install )`, `( . "$script"; verify )`. So a `PATH` (or any env) exported INSIDE
  `install()` does NOT carry to the later `verify()` call. Only env exported by the ENGINE inherits.
- Non-idempotent custom item: engine runs pre-check (`check`) → if pass, "already present, skip";
  else `install()` → **post-verify (`verify` else `check`)**. Post-verify FAIL → engine `exit 67`
  which **ABORTS THE WHOLE RUN** (fail-fast, all later bundles skipped). ← the dominant damage.
- Idempotent item (`idempotent: true` in manifest): engine SKIPS pre-check AND post-verify — only
  runs `install()` + records a marker. So path-fragility in `verify`/`check` does NOT bite idempotent
  items; `silent-install-pass` still does (a failed install records a false success).
- Engine runs **bash 3.2** on macOS. No assoc arrays, `${var,,}`, `mapfile`, gawk `IGNORECASE`.
- `3c70a15` already prepends `$BREW_PREFIX/bin:$BREW_PREFIX/sbin` → **bare brew tools now resolve**;
  do NOT "fix" bare brew lookups.

## 2 · The two root causes

**RC1 — engine PATH misses user tool dirs (same class as the brew fix).** The engine adds
`$BREW_PREFIX/bin` but not `~/.local/bin`, `~/.atuin/bin`, fnm's node-shim dir, or keg-only brew
`opt/<f>/bin`. A correctly-installed non-brew tool isn't found in the verify subshell → `rc67`
aborts the whole run.

**RC2 — `install()` returns 0 despite failure.** No `set -e`, `|| true` on load-bearing commands,
or the last statement is a no-op (a `PATH` export) → the engine records a false success, or (if
verify is strong) reports `rc67` instead of a clear "install failed".

## 3 · Implementation plan (waves) — DO IN THIS ORDER

### Wave 1 — systemic engine fix (1 commit, clears the biggest cluster)
Extend `scripts/lib/install-engine.sh` to also prepend **`$HOME/.local/bin`** to the item-subshell
PATH (mirror the `3c70a15` brew block; idempotent; not mac-only — `~/.local/bin` is the standard
user bin on mac AND wsl). Suggested placement: right after the brew block, or fold into a single
"build the item PATH" step. Snippet shape:

```bash
# Standard user bin: many installers (rtk, moshi-hook, rust bins, github-release, pip --user)
# drop executables in ~/.local/bin. Put it on PATH for every item subshell so a bare-name
# verify()/check() resolves them — same rationale as the Homebrew prepend above. Idempotent.
if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    PATH="$HOME/.local/bin:$PATH"; export PATH
fi
```
This clears (verify only): `topics/ai/install-rtk.sh`, `topics/ai/install-moshi-hook.sh`,
`topics/ai/moshi-hook-service-wsl.sh` (ExecStart resolution), `topics/shell-terminal/wsl/install-rust-bins.sh`.
**Still add per-script absolute fallbacks too** (Wave 2 belt-and-suspenders) so the scripts are
robust even if `~/.local/bin` doesn't exist yet at run time.
Add a regression test mirroring `tests/integration/engine-brew-path.test.sh` (a custom check needing
a bare tool that only lives in a temp `~/.local/bin`).

### Wave 2 — per-script PATH fallbacks (high) for dirs the engine won't add
Give `check()`/`verify()` an absolute-or-bare fallback (the pattern `install-bun.sh`/`install-claude.sh`
ALREADY use: `command -v X >/dev/null 2>&1 || [[ -x "$ABS" ]]`):
- `topics/shell-terminal/wsl/install-atuin.sh` + `topics/shell-terminal/atuin-login.sh` → `~/.atuin/bin/atuin`
- `topics/languages/node-fnm.sh` (WSL branch) → fnm at `~/.local/share/fnm`; also `eval "$(fnm env)"` before `fnm list` in verify, OR resolve node-shim dir
- `topics/databases/postgresql.sh:21` → keg-only `pg_isready` via `$BREW_PREFIX/opt/postgresql@<v>/bin` (or `brew --prefix postgresql@<v>`)
- `topics/web/mac/valet.sh` → also check `~/.config/composer/vendor/bin/valet` (composer home moved)
Also harden the Wave-1 scripts (`rtk`, `moshi-hook`, `rust-bins`) with the same fallback.

### Wave 3 — silent-install-pass (high): make install() fail loudly
Drop `|| true` on load-bearing commands / add `set -e` (or explicit `|| return 1`) so a real failure
returns non-zero (engine then says "install failed", not a misleading rc67) and never records a
false success:
- `topics/languages/node-fnm.sh` — guard `fnm install --lts` / the bare `fnm` calls; fail if node not present at end.
- `topics/languages/mac/php-stack.sh` + `topics/languages/wsl/php-stack.sh` — install runs without `set -e`; `fail()` is non-exiting; composer/PECL/apt failures must propagate.
- `topics/remote-access/mac/code-server.sh` — install swallows runtime-health failures; check/verify only test files-on-disk → a non-listening server is "installed".
- `topics/web/wsl/mkcert.sh` — wildcard cert gen failure masked → returns 0.
- `topics/web/mac/valet.sh` — `valet install`/`valet tld` failures `|| true` then re-surface as rc67.

### Wave 4 — medium/low (idempotency, readiness, portability, guards)
- `redis`/`mysql` (mac): `brew services start ... || true` + verify requires running → add a short
  readiness wait (retry `redis-cli ping`/`mysqladmin ping` ~3s) and/or surface the start rc.
- `install-rtk.sh:56-58` bash32: `awk 'BEGIN{IGNORECASE=1}'` is gawk-only → use `awk 'tolower($0) ~ /^location:/'` or `grep -i`.
- idempotency-asymmetry: `clone-fzf-tab`/`clone-p10k`/`clone-catppuccin` (non-git dir at $DEST), `enable-systemd-wsl` (blind `[boot]` append), `npm-global` (PATH fragments not checked), `syncthing-service-wsl` (enabled+active vs bare bg process), `identity/verify.sh` (id_ed25519 only vs check accepts id_rsa), `install-starship` rollback BIN_DIR mismatch.
- interactive-no-guard: `identity-setup.sh` (aborts under --non-interactive w/o GITHUB_TOKEN), `wsl/install-atuin.sh` (`[[ -t 0 ]]` instead of engine NON_INTERACTIVE), `launchdaemon-hardening.sh` (sudo w/o cache prime).
- weak-verify: `gitconfig-apply.sh` (asserts only first key), `syncthing-service-mac.sh` (returns 1/abort if UI not on :8384 within 20s), `php-stack/wsl` verify weaker than multi-PHP install promise.
- `orphan-ini-cleanup.sh` low: leaked mktemp dir.
- `moshi-hook-service-mac.sh` low: uses info()/followup() without sourcing log.sh.

## 4 · Verification recipe (per the prior fixes)
- After each script edit: `bash -n <script>`; for the engine: `bash bin/mesh lint` (rc 0).
- Reproduce a path-fragility fix on metal (mac): run the engine on just the bundle with a MINIMAL
  PATH to simulate the broken invocation, e.g.
  `printf '<topic>/<bundle>\n' > /tmp/s.list && /usr/bin/env -i HOME="$HOME" USER="$USER" TERM=dumb PATH=/usr/bin:/bin bash scripts/lib/install-engine.sh --selections /tmp/s.list --platform mac` → expect rc 0 / "already present".
- Engine suites: `bash tests/unit/install-engine.test.sh`, `bash tests/unit/uninstall-engine.test.sh`,
  `bash tests/integration/engine-brew-path.test.sh`.
- Menu (only if touching scripts/menu): `cd scripts/menu && npx tsc --noEmit && npx vitest run`.
- Commit discipline: small focused commits, never `--no-verify`, end body with the Co-Authored-By line.
- Update the initiative nextAction after each wave.

## 5 · Full findings (embedded — the audit deliverable)

Legend: severity · class · adversarial verdict. Files not listed here are clean (§6).


### CRITICAL (1)

#### `topics/databases/postgresql.sh` :21 — _path-fragility_ · **Wave 2** · ✅adversarially-confirmed
check()/verify() calls keg-only `pg_isready` by bare name → rc67 whole-run abort on macOS

- **What/why:** check() (also used as verify()) runs `pg_isready -q` by bare name. On macOS the postgres binary set comes from `brew install postgresql@N`, which is KEG-ONLY (confirmed: `postgresql@17 ... [keg-only]`). Brew does NOT symlink keg-only binaries into $BREW_PREFIX/bin — pg_isready lives only at $BREW_PREFIX/opt/postgresql@N/bin/pg_isready. The engine prepends only $BREW_PREFIX/bin:$BREW_PREFIX/sbin to PATH (install-engine.sh:148-149), NOT the opt/keg bin, and install-postgres.sh never runs `brew link postgresql@N`. So on a fresh macOS install: install() succeeds (heavy-lifter installs+starts postgres via its own absolute $BREW_PREFIX/opt/... paths), then the engine's POST-VERIFY calls custom_verify→check→`pg_isready` which is `command not found` (rc 127) → post-verify fails → engine `exit 67` ABORTS THE ENTIRE RUN, and rolls back this item, even though postgres is correctly installed and running. (The symlink present on this dev machine was created manually/externally and does not exist on a clean engine-driven install.) The dpkg/`brew list --formula` package check on the line above is fine; only the liveness probe is fragile.
- **Fix:** Resolve pg_isready via the version-specific opt path on macOS, e.g. `local pgready; if [[ "$(uname -s)" == Darwin ]]; then pgready="${BREW_PREFIX:-/opt/homebrew}/opt/postgresql@${ver}/bin/pg_isready"; else pgready=pg_isready; fi; "$pgready" -q 2>/dev/null`. Or relax verify so a keg-only-only-missing-from-PATH pg_isready is found via `command -v` fallback to the opt path. The package-presence assertion can stand alone if liveness can't be probed.


### HIGH (12)

#### `topics/ai/install-moshi-hook.sh` :20-22, 39-41 — _path-fragility_ · **Wave 1** · ✅adversarially-confirmed
WSL moshi-hook verify()=`command -v moshi-hook` with no fallback; installs to ~/.local/bin which engine never puts on PATH → rc67 abort

- **What/why:** install() (15-18) curls getmoshi.app/install.sh with INSTALL_DIR="$HOME/.local/bin" and exports NOTHING. verify() (20-22) is `command -v moshi-hook >/dev/null 2>&1` — bare lookup, no `[[ -x "$HOME/.local/bin/moshi-hook" ]]` fallback. The engine adds only $BREW_PREFIX/bin to the subshell PATH, not ~/.local/bin (install-engine.sh:148-149). moshi-hook is non-brew on WSL. If ~/.local/bin isn't already on the inherited PATH, post-verify fails after a correct install → `exit 67` aborts the whole run. Same class as the rtk finding; this item is NOT marked idempotent in topics/ai/manifest.yaml so it goes through full pre-check→install→post-verify.
- **Fix:** verify() { command -v moshi-hook >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/moshi-hook" ]]; } and likewise add the fallback to check(). Or prepend ~/.local/bin in the engine item subshell.

#### `topics/ai/install-rtk.sh` :35-37, 28-33, 165-166 — _path-fragility_ · **Wave 1** · ✅adversarially-confirmed
verify()/check() resolve rtk by bare name only; ~/.local/bin not on engine PATH → rc67 whole-run abort after a SUCCESSFUL install

- **What/why:** rtk installs to RTK_INSTALL_DIR=~/.local/bin (line 24) and install() ends with `PATH="$RTK_INSTALL_DIR:$PATH"; export PATH` (165-166). But that export lives only in install()'s subshell. custom_verify runs verify() in a SEPARATE subshell (`( . "$script"; verify )`), so the PATH change does NOT carry. verify()→check() does `command -v rtk >/dev/null 2>&1 || return 1` then `rtk gain` (28-33) — both bare lookups with NO absolute-path fallback. The engine only prepends $BREW_PREFIX/bin (install-engine.sh:148-149); it does NOT add ~/.local/bin. rtk is a non-brew tool. So on any run where the invoking shell's PATH lacks ~/.local/bin (early bootstrap, remote `mesh` wrapper, before shell fragments are deployed), post-verify fails even though the binary was installed correctly → engine `exit 67` aborts the ENTIRE run, skipping all later bundles. Contrast install-bun.sh/install-claude.sh which guard the identical case with `[[ -x "$HOME/.../bin/<tool>" ]]`.
- **Fix:** Give check() an absolute-path fallback like bun/claude: `command -v rtk >/dev/null 2>&1 || [[ -x "$RTK_BINARY" ]]`, and when invoking the collision-guard prefer the absolute binary: `"$RTK_BINARY" gain >/dev/null 2>&1 || rtk gain >/dev/null 2>&1`. Or have the engine prepend ~/.local/bin for every item subshell (same fix-shape as the brew prepend).

#### `topics/ai/moshi-hook-service-wsl.sh` :21, 27, 36, 40 — _path-fragility_ · **Wave 1** · ✅adversarially-confirmed
Service install resolves moshi-hook by bare name under `set -e`; the binary lives in ~/.local/bin (not on engine PATH) → empty ExecStart or hard abort

- **What/why:** Top-level `set -euo pipefail` (line 6) applies inside the install() subshell. install() builds the unit with `--exec "$(command -v moshi-hook)"` (line 21). The bundle order in topics/ai/manifest.yaml runs moshi-hook-linux (install to ~/.local/bin) before moshi-hook-wsl-service, but the engine never adds ~/.local/bin to PATH, so `command -v moshi-hook` can resolve to empty → user_service_install gets `--exec ""` and returns 1 ("--name and --exec are required", user-service.sh:52-55) → under set -e install() aborts → engine rollback+abort. Lines 27/36 also call bare `moshi-hook status`/`moshi-hook install` (guarded by `|| true`, so cosmetic), and verify() (40) is bare `pgrep ... -f 'moshi-hook'` which is fine, but the ExecStart resolution is the load-bearing failure.
- **Fix:** Resolve the binary by absolute path with a fallback: `bin="$(command -v moshi-hook || true)"; [ -n "$bin" ] || bin="$HOME/.local/bin/moshi-hook"; [ -x "$bin" ] || { echo 'moshi-hook not found' >&2; return 1; }` then pass `--exec "$bin"`. Mirror install-moshi-hook.sh's install dir.

#### `topics/shell-terminal/wsl/install-rust-bins.sh` :38-51 — _path-fragility_ · **Wave 1** · ✅adversarially-confirmed
check()/verify() resolve dust/xh/procs by bare name but install targets ~/.local/bin, which the engine does not put on PATH (whole-run rc67 abort)

- **What/why:** Manifest entry rust-bins-wsl (topics/shell-terminal/manifest.yaml:144-147) is NOT marked idempotent, so the engine runs the full pre-check -> install -> POST-VERIFY cycle. install() (L44-49) writes binaries to absolute $HOME/.local/bin (works regardless of PATH). But check() (L38-42) and verify()=check() (L51) resolve the binaries with `command -v dust/xh/procs`. ~/.local/bin is NOT a brew prefix, and the engine only prepends $BREW_PREFIX/bin on macOS (install-engine.sh:134-153); these items are platforms:[wsl] so they run on Linux where no brew PATH injection happens. setup.sh itself (lines 293-294) acknowledges ~/.local/bin is frequently absent from $PATH on a fresh bootstrap. Consequences: (1) install() always re-installs because its own `command -v dust || _install_dust` guards (L46-48) never see the freshly installed bins; (2) far worse, the engine post-verify runs verify()=check() in a separate subshell, `command -v` fails, _post_ok=0 -> the engine `exit 67` which ABORTS THE ENTIRE RUN, skipping every later bundle, even though all three binaries were correctly installed.
- **Fix:** Verify by absolute path, not PATH lookup: check()/verify() should test `[[ -x "$HOME/.local/bin/dust" && -x "$HOME/.local/bin/xh" && -x "$HOME/.local/bin/procs" ]]` (mirroring rollback() on L53-57 which already uses the absolute path). Optionally also prepend ~/.local/bin to PATH inside install() so the per-binary guards short-circuit on re-runs.

#### `topics/languages/node-fnm.sh` :10-18 (install WSL branch), 4-7 (check), 28 (verify) — _path-fragility_ · **Wave 2** · ✅adversarially-confirmed
WSL fnm installed to ~/.local/share/fnm is not on the verify-subshell PATH → bare `command -v fnm` fails in post-verify

- **What/why:** On WSL the install branch runs the curl installer with --skip-shell (line 15) which drops the fnm binary into $HOME/.local/share/fnm, then does `PATH="$HOME/.local/share/fnm:$PATH"; export PATH` (line 16) — but that export only lives inside the install() subshell. fnm is NOT a brew tool and ~/.local/share/fnm is NOT one of the dirs the engine prepends ($BREW_PREFIX/bin:sbin per commit 3c70a15). The engine runs post-verify check()/verify() in a SEPARATE per-verb subshell (`( . "$script"; verify )`) that never re-establishes that PATH, so `command -v fnm` (check line 5) returns non-zero → check fails → post-verify fails → engine `exit 67`, aborting the whole run even though the WSL install actually succeeded. Same root cause makes a later re-run's pre-check falsely report 'not installed' and reinstall churn.
- **Fix:** In check()/verify() (or via a shared helper sourced by both), add ~/.local/share/fnm (and the fnm shims dir) to PATH before the `command -v fnm` lookup, mirroring what install() does — e.g. `PATH="$HOME/.local/share/fnm:$PATH"`. Better: resolve fnm by explicit path fallback when bare lookup fails, then `eval "$(fnm env)"` so `fnm list` sees the managed node shims.

#### `topics/shell-terminal/wsl/install-atuin.sh` :2,4-10,12 — _path-fragility_ · **Wave 2** · ✅adversarially-confirmed
atuin verify() looks up `atuin` by bare name, but the official installer puts it in ~/.atuin/bin which is NOT on the engine item-subshell PATH → rc67 whole-run abort

- **What/why:** Manifest `atuin-wsl` (manifest.yaml:140-143) is type=custom and NOT idempotent, so the engine runs install() then POST-VERIFY verify()=check()=`command -v atuin`. The official setup.atuin.sh installs the binary to $HOME/.atuin/bin/atuin on Linux (confirmed: templates/cli-tools/{zshrc,bashrc}.d-20-terminal-ux.sh.template source $HOME/.atuin/bin/env to expose it). The engine only prepends $BREW_PREFIX/bin:$BREW_PREFIX/sbin to the item-subshell PATH (install-engine.sh:148-149) and env.sh adds nothing; ~/.atuin/bin is never added. So in the fresh verify() subshell `command -v atuin` returns non-zero, post-verify fails, and the engine `exit 67` ABORTS THE ENTIRE RUN (all later bundles skipped). The installer DOES edit shell rc files, but that does not affect the already-running engine subshell. Proof this path is a known hazard: the sibling atuin-login.sh check()/install() each begin with `command -v atuin >/dev/null 2>&1 || return 0` precisely to tolerate atuin not being on PATH — install-atuin's verify() has no such fallback.
- **Fix:** In check()/verify() fall back to the absolute path when bare lookup fails, e.g. `command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]]`. (Optionally `export PATH="$HOME/.atuin/bin:$PATH"` at the top of the script so install side-effects and the test agree.)

#### `topics/languages/mac/php-stack.sh` :27-550 (install body; no set -e), 138-196 (install_composer + fail), 552-554 (verify) — _silent-install-pass_ · **Wave 3** · ✅adversarially-confirmed
php-stack install() runs WITHOUT set -e and uses non-exiting fail() → returns 0 on genuine composer/PECL failure; thin verify can't catch it

- **What/why:** The script has NO `set -euo pipefail` (the only `set -e` is at line 511, inside the heredoc that goes into the GENERATED composer wrapper, not into install()). But comments at lines 99 and 412 explicitly reason about `set -e` exiting the script — that protection is inherited from the original install.mac.sh and DOES NOT EXIST when the engine sources this and calls install() in a plain subshell. Compounding it, log.sh `fail()` (verified: scripts/lib/log.sh:29) only prints to stderr and RETURNS 0. So idioms like `composer_is_usable || fail "..."` (lines 163, 168, 174, 179, 191, 194) and `composer_is_usable || fail` never abort — the `||` is satisfied by fail's rc 0. install_composer() can thus 'complete' with a broken/unusable composer. install() is NON-idempotent, and its last statement is `ok "10-languages done..."` (line 549) which returns 0, so install() reports SUCCESS regardless of any brew/PECL/composer failure accumulated along the way. Post-verify verify() (lines 552-554) is only `command -v php && command -v composer` — those resolve by bare name now that brew bin is on PATH, so verify PASSES even when every PECL extension failed to build and composer is the broken-PHAR brew bottle. Net: real failures are recorded as a successful install (marker written), the opposite of fail-fast.
- **Fix:** Either add `set -euo pipefail` at the top of the script body (and audit the many `|| true` / retry-tier paths that currently rely on its absence), or make the critical helpers `return 1` and have install() propagate: track a failure flag (you already have BREW_INSTALL_FAILED) and `return 1` at the end if composer is unusable or required extensions are missing. Strengthen verify() to assert composer actually runs (`composer --version`) and that declared PHP_VERSIONS are brew-linked, matching check()'s stronger contract (lines 13-24).

#### `topics/languages/node-fnm.sh` :9-26 (install), 4-7 (check/verify) — _silent-install-pass_ · **Wave 3** · ✅adversarially-confirmed
fnm install() returns 0 even when node never gets installed → post-verify rc67 aborts whole run

- **What/why:** node-fnm is a NON-idempotent item (no idempotent: true in manifest, lines 25-30), so the engine does pre-check → install → POST-VERIFY (verify()=check()). install()'s last effective statement is the line `[[ -n "$default_ver" ]] && fnm default "$default_ver" || true` (line 24), which always evaluates to 0 because of the trailing `|| true`. Critically, `fnm install --lts` (line 21) is NOT error-checked at all — if it fails (network, mirror, no matching LTS), nothing aborts install(), and `default_ver` (line 23) comes back empty, so the `&& ... || true` chain still returns 0. install() therefore reports SUCCESS while no node version exists. The engine then runs post-verify check() (lines 4-7): `command -v fnm && fnm list | grep -qE 'v[0-9]+...'`. With no node installed that grep fails → check returns 1 → engine `exit 67` which ABORTS THE ENTIRE RUN (all later bundles skipped). This is the exact node-fnm exemplar pattern from the rubric. The mismatch: install promises 'fnm + an LTS node', verify asserts a node exists, but install's success path doesn't guarantee it.
- **Fix:** Make install() fail loudly when node isn't established: capture `fnm install --lts` rc and `return 1` on failure; after the install attempt, re-run the `fnm list | grep -qE 'v[0-9]'` assertion and `return 1` if still empty. That converts a misleading rc67 'verify failed' (whole-run abort) into a truthful 'install failed' rc for THIS item, and lets the engine's rollback/abort logic report the real cause.

#### `topics/languages/wsl/php-stack.sh` :27-245, 89, 143, 150, 247-249 — _silent-install-pass_ · **Wave 3** · ✅adversarially-confirmed
install() has no set -e; a mid-function `sudo apt-get install` failure is non-fatal and the function returns 0 via its final `ok`, while verify() is too weak to catch partial install

- **What/why:** install() (line 27) never sets `-e`. The body is a long imperative sequence of `sudo apt-get install -y -qq ...` calls (lines 89, 143, 150) and pecl_install loops, with the LAST statement being `ok "10-languages done — PHP default: $PHP_DEFAULT"` (line 244), and `ok()` in log.sh is just a printf → returns 0. So if any apt/pecl step fails mid-way (e.g. a php8.5-dev or PECL build failure, or ondrej PPA add fails), execution simply continues and install() still returns 0. The engine (non-idempotent item) then runs post-verify=verify() which only checks `command -v php && command -v composer` (line 248). Since the default php + composer usually do install successfully, verify passes — so a run where a non-default PHP version or a PECL extension silently failed is recorded as a full success. Worse, this disagrees with check() (lines 6-25) which requires EVERY declared php${ver}-fpm present: a partial install passes verify() but fails check(), so the very next bootstrap re-runs the whole install (churn) instead of surfacing the earlier failure.
- **Fix:** Add `set -euo pipefail` to install() (it runs in the driver's sourced subshell, so failure → non-zero rc → engine logs `install failed` + rollback, instead of rc67/false-success), OR explicitly check the rc of each apt/pecl step. Also strengthen verify() to assert the declared PHP_VERSIONS' fpm packages (mirror check's dpkg loop) so a partial install does not read as done. WSL-only, so no bash 3.2 concern.

#### `topics/remote-access/mac/code-server.sh` :740-754, 521-535, 537-561, 5-17, 756 — _silent-install-pass_ · **Wave 3** · ✅adversarially-confirmed
install() swallows runtime-health failures (no set -e); check()/verify() only test files-on-disk, so a non-listening code-server is recorded as installed

- **What/why:** install() (line 19) has NO `set -e`. Its body ends with the flat, unchained call sequence at lines 740-751. Two of those calls report failure via `return 1` rather than `exit 1`: wait_for_healthz (line 534, the LaunchAgent bootstrapped but :8080/healthz never responded in 30s) and verify_local_only_listener (lines 547/557, no listener / wrong bind). Because there is no `set -e` and no `||`/`&&` guarding, a `return 1` from these does NOT stop install(); execution falls through to deploy_user_settings_from_identity, maybe_configure_tailscale_serve, and finally `ok "85-code-server done"` (line 753) which returns 0. So install() returns 0 even when code-server never came up. The item is non-idempotent, so the engine then runs post-verify = verify() = check() (line 756 / 5-17), which only asserts the binary, plist and config.yaml exist on disk — all of which WERE written before the health step. Net: a dead/non-listening code-server is recorded as a successful install and the run continues. (The binary-acquire and precondition functions correctly use `exit 1`, so only the runtime-health gap is masked.)
- **Fix:** Either add `set -euo pipefail` at the top of install() (most functions already `exit 1`, so this is mostly safe and would turn the two `return 1` paths into aborts → engine rc != 0 = real install-failed), or chain the tail sequence with `&&`, or convert wait_for_healthz/verify_local_only_listener to `exit 1`. Separately, verify() should assert the listener is actually up (e.g. reuse wait_for_healthz / lsof loopback check) rather than only file presence.

#### `topics/web/mac/valet.sh` :26-46, 48-50 — _silent-install-pass_ · **Wave 3** · ✅adversarially-confirmed
valet install/tld failures swallowed by `|| true` then re-surface as rc67 whole-run abort

- **What/why:** install() runs `"$VALET_BIN" install || true` (lines 27, 29), `valet tld localhost || echo ...` (lines 41-42) and `( cd ... && valet park ) || true` (line 45). Every real failure is masked, so install() returns 0 regardless. But verify()=check() (lines 48-49 -> 7-16) independently ASSERTS that `~/.config/valet` exists AND config.json has `"tld": "localhost"`. Under the engine's non-idempotent flow, if `valet install` fails (sudo not cached / no TTY / DNSMasq port busy) ~/.config/valet is never created -> install returns 0 -> POST-VERIFY check() returns 1 -> engine `exit 67` ABORTS THE ENTIRE RUN (all later bundles skipped). The user sees a misleading 'post-install verification failed' instead of the actual 'valet install failed', and one optional extra takes down the whole bootstrap. Same trap if `valet tld localhost` fails: config.json keeps the old TLD, check's grep fails, rc67.
- **Fix:** Capture rc of the load-bearing steps (`valet install`, `valet tld localhost`) and `return 1` on real failure so the engine reports 'install failed' (clean, with rollback) rather than rc67 whole-run abort. Keep `valet park` best-effort (`|| true`) since check() does not assert parking. At minimum, drop `|| true` on `valet install` when ~/.config/valet is absent.

#### `topics/web/wsl/mkcert.sh` :42-53, 91, 93-95 — _silent-install-pass_ · **Wave 3** · ✅adversarially-confirmed
Wildcard cert generation failure is masked; install() returns 0 -> rc67 whole-run abort

- **What/why:** There is no `set -e` inside install(). The cert-generation block (lines 43-53) runs `( cd "$tmp" && mkcert ... )` then two `sudo install ...` with NO rc check, and install() then continues into the Windows-trust section whose every branch ends in an `echo` returning 0 (lines 67-90). So install()'s final return code is 0 even if `mkcert` failed to emit the PEMs or `sudo install` failed to place them. verify()=check() (lines 93-95 -> 16-18) then ASSERTS `test -f $WILDCARD_PEM` AND `test -f $WILDCARD_KEY`. If generation failed, the files are absent -> post-verify fails -> engine `exit 67` ABORTS THE ENTIRE RUN, reported as a verify failure rather than the real 'mkcert failed'. Note mkcert -install on line 38 is correctly best-effort (`|| echo`), but the cert MATERIALIZATION on 46-51 is load-bearing for verify and is unguarded.
- **Fix:** Guard the generation block: capture rc of the `( cd ... mkcert ... )` subshell and of each `sudo install`, and `return 1` on failure so the engine reports a clean install failure. Keep the Windows-trust import best-effort (verify doesn't assert it).


### MEDIUM (11)

#### `topics/shell-terminal/atuin-login.sh` :6, 19 — _path-fragility_ · **Wave 2**
Bare `atuin` lookup fails on WSL (atuin lives in ~/.atuin/bin, not on engine PATH) → login feature silently never runs

- **What/why:** Both check() (line 6) and install() (line 19) gate on `command -v atuin >/dev/null 2>&1 || return 0`. On macOS atuin is brew-installed (atuin-mac brew-formula) so it resolves via the engine's $BREW_PREFIX/bin prepend. But on WSL atuin is the `atuin-wsl` custom item installed by wsl/install-atuin.sh, which uses the official `curl ... | sh` installer that drops the binary in ~/.atuin/bin/atuin and only wires it into the shell rc — NOT onto the engine item-subshell PATH (the engine prepends only $BREW_PREFIX/bin, and there is no brew prefix on WSL). So inside the engine subshell `command -v atuin` returns non-zero even though atuin IS installed. Both check() and install() then take the `|| return 0` skip path: check() reports success (engine logs 'already present, skipping') and install() never runs `atuin login`. The cross-machine-history login the script exists to perform silently never happens on WSL. This is NOT a run-abort (returns 0 everywhere) — it's a defeated feature, hence medium.
- **Fix:** Resolve atuin via an absolute fallback when the bare lookup misses: e.g. `command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]] || return 0`, and invoke it through a resolved ATUIN var (PATH-prepend ~/.atuin/bin at the top of the script). Mirror the same resolution in check()/install()/verify().

#### `topics/shell-terminal/wsl/install-delta.sh` :6,7-11 — _path-fragility_ · **Wave 2**
delta install() hard-depends on `jq` (and an undeclared GitHub API call) with no guard; jq is not installed by the cli-tools bundle before git-delta-wsl

- **What/why:** install() runs `ver="$(curl ... | jq -r '.tag_name')"`. jq is a base/foundation tool on this stack (topics/foundation manifest mentions jq), so it is usually present — but it is NOT installed by any item in the shell-terminal cli-tools bundle before git-delta-wsl (manifest.yaml:136-139), so on a machine where the foundation jq install was skipped/failed, jq is absent. If jq is missing, `ver` becomes empty, the download URL collapses to `git-delta__amd64.deb`, `curl -fsSL` fails (good: -f), and `sudo dpkg -i` then fails on the missing file → install returns non-zero. That at least surfaces as 'install failed' (not a false success), so this is medium not high; but the dependency is implicit and the GitHub API rate-limit (HTTP 403, unauthenticated) is another silent way `ver` becomes empty/`null`. Note delta itself lands in /usr/bin via dpkg, which IS on PATH, so verify()=`command -v delta` is fine.
- **Fix:** Guard jq up front: `command -v jq >/dev/null 2>&1 || { echo '[delta] jq required' >&2; return 1; }`. Validate `ver` is non-empty and not 'null' before building the URL, and `trap 'rm -rf "$tmp"' RETURN` so the tmp dir is cleaned even on early failure.

#### `topics/web/mac/valet.sh` :4, 19, 22 — _path-fragility_ · **Wave 2**
Hard-coded `~/.composer/vendor/bin/valet` misses the composer ~/.config/composer home

- **What/why:** VALET_BIN is hard-pinned to `$HOME/.composer/vendor/bin/valet`. Composer (brew-installed here, so `composer` itself resolves fine on the engine PATH) places its global bin under `$COMPOSER_HOME/vendor/bin`, which is `~/.config/composer/vendor/bin` when XDG is set or on newer composer defaults, NOT `~/.composer`. If composer resolves its home to ~/.config/composer, `composer global require laravel/valet` succeeds but VALET_BIN never becomes executable -> line 22 `[[ -x "$VALET_BIN" ]] || { echo 'composer install failed'; return 1; }` fires a false 'composer install failed', or (if a stale ~/.composer exists) silently runs the wrong binary. This is the valet binary path (not a brew tool), so the engine's BREW_PREFIX PATH-prepend does not help.
- **Fix:** Resolve the bin dir from composer at runtime: `valet_bin="$(composer global config --absolute bin-dir 2>/dev/null)/valet"` (fall back to ~/.composer and ~/.config/composer), instead of hard-coding ~/.composer.

#### `topics/databases/mac/mysql.sh` :210-215, 180-195 — _silent-install-pass_ · **Wave 3**
Canonical-prefix path masks `brew services start` failure with `|| true` while check() requires a running server → rc67 whole-run abort

- **What/why:** check() (180-195) for the canonical-prefix case requires the formula installed AND `_server_running` (live mysqld OR managed launchctl unit OR brew-services 'started'). install() path 2 (210-215) runs `brew install mysql` then `"${BREW_BIN:-brew}" services start "$MYSQL_SVC" >/dev/null 2>&1 || true; return 0`. If `services start` fails (e.g. first-boot datadir not yet initialized, socket conflict, perms), install() returns 0, post-verify check() sees no running server → `exit 67` aborts the entire run (this is a tier-3 DB item; aborting here strands every later bundle). Unlike the Oracle-tarball path (which inits the datadir and drives the launch-wrapper), the brew path does no readiness check.
- **Fix:** Surface the brew-services start rc as an install failure instead of `|| true`, or add a short readiness wait in _server_running (retry pgrep/`mysqladmin ping`) so a daemon that is still initializing on first start is not misclassified as a verify failure.

#### `topics/databases/mac/redis.sh` :23-36 — _silent-install-pass_ · **Wave 3**
install() masks `brew services start` failure with `|| true` while check()/verify() require a RUNNING server → rc67 instead of a clean install-failed

- **What/why:** check()/verify() (12-21) require redis to be actually running (pgrep redis-server OR launchctl-running OR `brew services list` shows 'started'). The canonical branch of install() does `"${BREW_BIN:-brew}" services start redis >/dev/null 2>&1 || true` (35) — if the service fails to start (port in use, plist conflict, stale state), install() still returns 0, then post-verify check() finds nothing running → engine `exit 67` aborts the whole run. There is also a start-race: pgrep immediately after `services start` may miss a daemon still spawning. The non-idempotent classification (no `idempotent:` in manifest) means this verify gate is enforced every run.
- **Fix:** Drop the `|| true` and surface a start failure as an install failure (clearer rc than 67), and/or add a brief readiness wait/retry in verify() (e.g. loop pgrep/`redis-cli ping` up to ~3s) so a slow-starting daemon is not misread as failed.

#### `topics/languages/mac/php-stack.sh` :162-163, 178-191 (composer reinstall paths) — _silent-install-pass_ · **Wave 3**
`brew reinstall` / source-build composer results are not checked before declaring success

- **What/why:** Inside install_composer(), `"$BREW_BIN" reinstall --build-from-source composer` (lines 162, 190) is run unguarded; the following `composer_is_usable || fail ...` (lines 163, 191) cannot abort because fail() returns 0 (see above), and there is no `set -e`. So a failed reinstall still falls through to `return 0`. Because php-stack is non-idempotent and install() ultimately returns 0 via the trailing `ok`, a broken composer is recorded as installed; verify() (`command -v composer`) still passes because the brew-shimmed binary exists on PATH even when its PHAR signature is broken — exactly the bug these branches were written to fix.
- **Fix:** Guard each reinstall/source-build with an explicit usability gate that returns non-zero, e.g. `"$BREW_BIN" reinstall ... composer; composer_is_usable || return 1`. Then ensure install() propagates that non-zero up so the engine reports a real install failure instead of a false success.

#### `topics/shell-terminal/wsl/install-rust-bins.sh` :5-36 — _silent-install-pass_ · **Wave 3**
_install_* helpers can return 0 after a failed download/extract, masking install failure as a verify failure

- **What/why:** Each helper (_install_dust L5-14, _install_xh L16-25, _install_procs L27-36) chains `curl -fsSL -o ...` then `tar`/`unzip` then `install` then `rm -rf`. The helpers run without `set -e` (custom scripts are sourced into the engine subshell, not run with -e). If `curl` fails (network/rate-limit) the file is missing, `tar`/`unzip` errors, `install` errors — but these are separate statements; the function's return code is whatever the LAST statement (`rm -rf "$tmp"`, L13/24/35) returns, which is 0. Also `ver=$(curl ... | jq ...)` (L7/18/29) can yield an empty string on GitHub API rate-limit, producing a 404 download URL. Net effect: install() returns 0 even though nothing was installed, and the engine then reports the symptom as 'verify failed' (rc67 abort) rather than 'install failed', obscuring the real cause. With the path-fragility fix above unmasked, a genuinely-failed download would still surface as a confusing rc67.
- **Fix:** Make each helper fail fast: either add `set -e` locally / `|| return 1` after curl/tar/unzip/install, or end each helper by asserting the target exists: `[[ -x "$HOME/.local/bin/dust" ]]`. Also guard empty `ver` (`[[ -n "$ver" ]] || return 1`).

#### `topics/web/mac/launchdaemon-hardening.sh` :37, 46-54, 56-64 — _silent-install-pass_ · **Wave 3**
PlistBuddy Set/Add failure not propagated; install returns 0 while verify asserts the edited path

- **What/why:** On a custom BREW_PREFIX, install() edits each present plist's StandardErrorPath via `PlistBuddy Set ... || PlistBuddy Add ...` (lines 47-48) and StandardOutPath via `PlistBuddy Set` (line 52), with no rc capture, then `return 0` (line 65). verify()=check() (lines 68-69 -> 18-33) asserts every present plist has `StandardErrorPath == target`. If PlistBuddy Set AND Add both fail (e.g. TCC/SIP denies write, or sudo not cached so it errors non-interactively), install still returns 0 but the path was never set -> post-verify returns 1 -> engine `exit 67` ABORTS THE WHOLE RUN, surfaced as a verify failure. Lower severity than valet/mkcert because the most common failure (bootstrap/bootout) IS handled non-fatally on lines 60-62, and this only bites when the plist edit itself is denied.
- **Fix:** Capture rc of the PlistBuddy Set/Add for StandardErrorPath; if it fails, `return 1` so the engine reports a clean install failure with the real cause, instead of an opaque rc67.

#### `topics/ai/install-rtk.sh` :56-58 — _bash32-incompat_ · **Wave 4**
`awk 'BEGIN{IGNORECASE=1}'` is a gawk-only extension; macOS BSD awk silently ignores it, so the primary (no-rate-limit) tag-resolution path never matches a capital `Location:` header

- **What/why:** _rtk_latest_tag (56-58) parses the 302 redirect from /releases/latest with `awk 'BEGIN{IGNORECASE=1} /^location:/'`. On macOS the engine's /usr/bin/awk is BSD awk (verified: version 20200816), where IGNORECASE is a no-op — `/^location:/` will NOT match a `Location:` header (capital L), which is exactly what curl -sSI emits for HTTP/1.1 redirect responses. When it fails to match, `v` is empty and the code falls back to the unauthenticated GitHub API (61-64) — the very rate-limited path the header trick was written to avoid (see the file's own comment at lines 7-9). HTTP/2 responses use lowercase `location:` so it sometimes works, making this an intermittent, host-dependent degradation rather than a hard break.
- **Fix:** Make the match portable: `awk 'tolower($0) ~ /^location:/ {print}'` (works on both BSD and gawk), or `grep -i '^location:'`. Then the no-rate-limit path works on mac as intended.

#### `topics/syncthing/syncthing-service-wsl.sh` :5-26 — _idempotency-asymmetry_ · **Wave 4**
check() asserts the systemd unit is enabled+active but the install() manual-fallback path only backgrounds a bare process — check/verify disagree and re-install churns

- **What/why:** check() (L5-8) requires BOTH `systemctl --user is-enabled` AND `is-active` to pass. install() (L10-22) tries `systemctl --user enable --now`; on failure it falls back to `syncthing serve --no-browser & ; disown` (L17-21). verify() (L24-26) only checks `pgrep -u $USER -f syncthing`. So the fallback path establishes a state that satisfies verify() but NOT check(). Two consequences: (1) the fallback install() returns 0 because its last statement is `disown` (rc0) even if the systemctl enable failed — and if the backgrounded `syncthing serve` dies immediately (e.g. config error), pgrep may still catch it within the same instant or not, making verify() flaky. (2) On the NEXT engine run, the pre-check check() fails (unit never got enabled) so the item re-installs every time — permanent churn, never recorded as 'already present'. The asymmetry is the root issue: check() is a strict superset of what the fallback install establishes.
- **Fix:** Align the predicates. Either make verify() match check() (require the unit enabled+active) so the manual fallback is honestly reported as not-fully-installed, or have check() accept the running-process state too (e.g. OR in the pgrep test) so a successfully-running fallback is recognized as 'already present' and not re-run. Also have the fallback branch propagate a non-zero rc when the systemctl path failed AND the background process is not confirmed alive.

#### `topics/languages/wsl/php-stack.sh` :6-25, 247-249 — _weak-or-missing-verify_ · **Wave 4**
verify() is strictly weaker than check() and than install's promise (multi-PHP), creating idempotency asymmetry

- **What/why:** check() requires composer, python3, AND every declared php${ver}-fpm installed via dpkg (lines 6-24). verify() only requires `command -v php && command -v composer` (line 248). install()'s promise is the full multi-version stack + PECL + per-version composer wrappers + python. So verify() under-asserts: a post-install state with only the default php + composer (no python3, missing secondary versions, missing PECL) passes verify() but fails the next run's check() → re-install churn every bootstrap, and masks partial failures. This is the same class of weakness Codex flagged for check() in the file header (E-F002) but the fix was only applied to check(), not verify().
- **Fix:** Make verify() at least as strong as check() (call check, or duplicate its dpkg/python3 assertions) so post-verify and the idempotency pre-check agree on what 'installed' means.


### LOW (19)

#### `topics/ai/install-bun.sh` :10-14 — _silent-install-pass_ · **Wave 3**
install() always returns 0 (last stmt is PATH export) — a failed `curl | bash` is only caught by verify() as rc67, not reported as an install failure

- **What/why:** install() (10-14) is `curl -fsSL https://bun.sh/install | bash` with no `set -o pipefail` and the final statement `PATH=...; export PATH` (always rc 0). So if the download/install pipe fails, install() still returns 0. The item is non-idempotent, so post-verify runs check() which has a real absolute-path test (`[[ -x "$HOME/.bun/bin/bun" ]]`) and correctly fails → engine `exit 67`. Net effect: a network/install failure surfaces as a confusing 'post-install verification failed' (rc67, whole-run abort) instead of a clear 'install failed (rc=N)'. The PATH export at line 13 is also dead — it runs in install()'s subshell and never reaches verify()'s subshell. Not data-unsafe, just a misleading failure mode and dead code; check()'s absolute fallback keeps it correct.
- **Fix:** Add `set -o pipefail` (or capture: `if ! curl -fsSL https://bun.sh/install | bash; then return 1; fi`) so a real install failure is reported as install-failed rather than verify-failed. Drop the no-op PATH export or move the logic into check() (which already covers it).

#### `topics/ai/install-claude.sh` :8-11 — _silent-install-pass_ · **Wave 3**
install() always returns 0 (last stmt is PATH export); failed `curl | bash` only manifests as verify rc67

- **What/why:** Identical pattern to install-bun.sh: `curl -fsSL https://claude.ai/install.sh | bash` with no pipefail, final statement is the PATH export (rc 0), so install() can return 0 on a failed install. check()/verify() has a real absolute-path fallback (`[[ -x "$HOME/.local/bin/claude" ]]`) so correctness is preserved, but a download failure is reported as post-install-verification-failed (rc67 whole-run abort) rather than install-failed. The PATH export (line 10) is dead (different subshell from verify()).
- **Fix:** Add `set -o pipefail` or check the pipe rc explicitly so install failure is reported as install failure; the PATH export can be removed since check() already tests the absolute path.

#### `topics/remote-access/install-tailscale-wsl.sh` :8-10 — _silent-install-pass_ · **Wave 3**
`curl -fsSL ... | sh`: curl failure is masked by the pipe (sh exits 0 on empty input); relies entirely on post-verify to catch it

- **What/why:** install() is a single `curl -fsSL https://tailscale.com/install.sh | sh`. In a pipe, the function's exit code is that of `sh`, not curl. If curl fails (network/DNS/4xx), `sh` receives empty stdin and exits 0, so install() returns 0 even though nothing was installed. Because the item is non-idempotent, the engine then runs post-verify=verify()=`command -v tailscale` which correctly fails → engine exits 67 and aborts the whole run. So the user-visible symptom is a confusing 'verify failed / whole-run abort' instead of a clear 'install failed (curl)'. Not a false-success (verify saves it), hence low.
- **Fix:** Capture the installer to a temp file first (`curl -fsSLo /tmp/ts.sh ... && sh /tmp/ts.sh`) or set `set -o pipefail` so curl's failure becomes the install rc and the engine reports 'install failed' rather than 'verify failed'.

#### `topics/languages/mac/orphan-ini-cleanup.sh` :22, 42 (mktemp per iteration; rmdir only-if-empty) — _destructive-or-unsafe_ · **Wave 4**
mktemp cleanup dir leaks in /tmp when an orphan ini is actually moved (rmdir only runs when empty)

- **What/why:** install() creates a fresh `mktemp -d -t orphan-ini-cleanup.XXXXXX` per php_ver_dir (line 22), moves any genuinely-orphaned 99-*.ini into it (line 37), then `rmdir "$cleanup_dir" 2>/dev/null || true` (line 42) which only succeeds if the dir is EMPTY. So in the (rare) case where it actually relocates an ini, the temp dir is intentionally kept 'for inspection' but never cleaned up and never surfaced to the user — it just accumulates in /tmp across runs. This item is marked idempotent: true (manifest line 65), so the engine re-runs it every pass, creating a new (usually-empty, harmlessly-rmdir'd) dir each time; only the move-path leaks. Not engine-breaking (install() returns the rc of the final `rmdir ... || true` = 0, which is fine for an idempotent item), purely a hygiene/leak issue.
- **Fix:** Only create the cleanup_dir lazily when the first orphan is found, and either emit its path via the followup() mechanism so the user knows where the quarantined inis went, or move to a stable mesh-managed quarantine dir under the state area rather than a per-run /tmp dir.

#### `topics/ai/install-moshi-hook.sh` :11-13 — _idempotency-asymmetry_ · **Wave 4**
check()=bare `command -v moshi-hook` (no ~/.local/bin fallback) → engine re-installs (re-curls) on every run when ~/.local/bin is off PATH

- **What/why:** Beyond the post-verify abort risk (separate high finding), the same bare-lookup check() (11-13) means the engine's PRE-check on a subsequent `mesh setup` returns 1 whenever ~/.local/bin is absent from the inherited PATH, so the item is treated as not-installed and install() re-runs the getmoshi.app curl every time. The file comment ('Update = re-run this installer') tolerates re-runs, but this turns every setup into an unnecessary network download + binary replace rather than a cheap idempotent skip.
- **Fix:** Add the absolute-path fallback to check(): `command -v moshi-hook >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/moshi-hook" ]]` so a present binary is detected and the curl is skipped on re-runs.

#### `topics/identity/verify.sh` :17 vs identity-setup.sh:12 — _idempotency-asymmetry_ · **Wave 4**
Topic verify only accepts id_ed25519 while identity-setup.check() also accepts id_rsa

- **What/why:** This is a TOPIC-level verify (run by the topic, not the custom-item driver) — note the distinction. identity-setup.sh check()/verify() (line 12) considers the SSH-key step satisfied by EITHER `~/.ssh/id_ed25519` OR `~/.ssh/id_rsa`. But topics/identity/verify.sh line 17 hardcodes `test -f $HOME/.ssh/id_ed25519` (and line 18 reads id_ed25519.pub). So a machine whose identity was set up with an existing id_rsa key passes the custom-item verify but FAILS the topic verify, reporting a spurious '✗ SSH key exists'. Cosmetic (topic verify is a report, set -euo pipefail just makes the script exit non-zero), but the two verifiers disagree on what 'installed' means.
- **Fix:** Align the topic verify with the installer's contract: accept id_ed25519 OR id_rsa (and derive the .pub from whichever exists) so the two layers agree.

#### `topics/languages/npm-global.sh` :10-13 (check) vs 64-69 (install) — _idempotency-asymmetry_ · **Wave 4**
check() validates only ~/.npmrc, not the shell PATH fragments install() writes → fragments not restored if deleted

- **What/why:** install() does three things: mkdir the global bin, ensure the npmrc `prefix=` line, and write PATH fragments into ~/.bashrc.d and ~/.zshrc.d (lines 67-68). But check()/verify() (lines 10-13) asserts ONLY that ~/.npmrc contains the prefix line. So if the npmrc line is present but a user (or a reset of the rc.d dirs) removed the PATH fragments, the engine's pre-check reports 'already present, skipping' and never re-creates the fragments — the npm-global bin silently drops off PATH. verify() is thus weaker than install's promise. Low impact: this item is `when: option.npm-global-prefix` gated and the rest of the script is solid (mktemp/awk/cmp idempotency, counter-suffixed backups, all system tools on PATH, no bash4 constructs).
- **Fix:** Extend check() to also require the two PATH fragments exist and match (e.g. reuse _path_fragment's cmp logic, or grep the managed marker line in ~/.bashrc.d/$NPM_GLOBAL_FRAGMENT_NAME and the zsh counterpart), so a missing fragment triggers a real re-install instead of a false 'already present'.

#### `topics/remote-access/enable-systemd-wsl.sh` :13-21, 5-11 — _idempotency-asymmetry_ · **Wave 4**
install() blindly appends a fresh `[boot]` section; on a wsl.conf that already has `[boot]` (without systemd) this writes a duplicate/ malformed section

- **What/why:** check() greps for an existing `^systemd = true` line (line 10) and gates install. install() (lines 14-18) appends a whole new `[boot]\nsystemd=true` block via `sudo tee -a`, unconditionally. If /etc/wsl.conf already contains a `[boot]` section (e.g. with other boot keys but no systemd), check() returns false and install() appends a SECOND `[boot]` section. The grep-based check then matches and verify() passes, so it is not a false-failure — but the resulting wsl.conf has duplicate `[boot]` stanzas, which some parsers handle by last-wins and others reject. Low engine impact (no abort), but it can produce a malformed config.
- **Fix:** Detect an existing `[boot]` section and add the `systemd=true` key under it (or use a managed_block helper) instead of always appending a new section. At minimum, only append `systemd=true` (no `[boot]`) when a `[boot]` header already exists.

#### `topics/shell-terminal/clone-fzf-tab.sh` :3-9 — _idempotency-asymmetry_ · **Wave 4**
Pre-existing non-git directory at $DEST makes the NON-idempotent git clone fail; only rollback rescues it

- **What/why:** Item fzf-tab is NON-idempotent (no `idempotent: true` in manifest.yaml), so the engine runs pre-check then install then post-verify. check() is `[[ -d "$DEST/.git" ]]`. If ~/.local/share/fzf-tab exists but is non-empty and lacks .git (a previously aborted clone, or a stray dir), check() returns false, install() runs `git clone ... "$DEST"`, and under the engine's inherited `set -e` git aborts with 'destination path already exists and is not an empty directory' → install fails → engine triggers rollback. rollback() does `rm -rf "$dir"` which clears it, so a subsequent run succeeds — self-healing, but the first run reports a (recoverable) failure. clone-p10k.sh has the identical shape. clone-tpm.sh and clone-catppuccin.sh carry explanatory comments; these two do not.
- **Fix:** Optional hardening: in install(), `rm -rf "$DEST"` (it is the managed clone target) before `git clone`, or `git clone` into a temp dir then mv. At minimum mirror the clone-tpm/clone-catppuccin comment documenting that rollback owns cleanup of a partial clone.

#### `topics/shell-terminal/clone-p10k.sh` :3-9 — _idempotency-asymmetry_ · **Wave 4**
Same partial-clone asymmetry as clone-fzf-tab (non-git dir at $DEST → clone fails, rollback rescues)

- **What/why:** Identical structure to clone-fzf-tab.sh: NON-idempotent item, check() tests `[[ -d "$DEST/.git" ]]` ($HOME/.local/share/powerlevel10k), install() does a bare `git clone` that fails under `set -e` if the dir exists without .git. rollback() rm -rf's it so the next run heals. git itself is brew/apt-managed so it resolves fine on the engine PATH — no path-fragility here. Filed low for the same first-run recoverable-failure window.
- **Fix:** Same as clone-fzf-tab: pre-clear $DEST in install() or clone-then-mv, and/or add the rollback-owns-cleanup comment for parity with clone-tpm/clone-catppuccin.

#### `topics/shell-terminal/wsl/install-starship.sh` :2-4 — _idempotency-asymmetry_ · **Wave 4**
rollback() removes /usr/local/bin/starship but the official installer's default BIN_DIR may differ from where verify() finds it

- **What/why:** install() pipes the official starship installer with `--yes` (L3). check()/verify() use `command -v starship` (L2,4) — PATH lookup. rollback() (L5-7) only removes /usr/local/bin/starship. The starship install.sh defaults BIN_DIR to /usr/local/bin on Linux, so on the happy path these align, but if the installer falls back to ~/.local/bin (no sudo) or honors a BIN_DIR override, rollback() would miss the real binary and verify() (PATH-based) could still pass post-rollback. This is non-idempotent in the manifest so it goes through pre-check/verify normally; the misalignment only bites the rollback path, hence low. Note also `curl | sh` swallows curl's exit via the pipe — a failed download still runs `sh` which exits 0, so a network failure surfaces as rc67-verify-fail rather than install-fail, but starship's own installer mitigates most of this.
- **Fix:** Have rollback() resolve the real path (`p=$(command -v starship); [[ -n "$p" ]] && sudo rm -f "$p"`) or pass an explicit BIN_DIR to the installer so install/rollback agree. Optionally `set -o pipefail` around the curl|sh to catch download failures as install failures.

#### `topics/identity/identity-setup.sh` :6-13 (check), 15-19 (install) + scripts/setup-identity.sh:90-95 — _interactive-no-guard_ · **Wave 4**
Non-idempotent identity-setup aborts the run under --non-interactive when no GITHUB_TOKEN (guarded, but fail-fast halts later bundles)

- **What/why:** identity-setup is non-idempotent (manifest lines 32-34, no idempotent flag), so on a fresh machine pre-check check() fails (gh not authed) → install() runs setup-identity.sh. That script IS properly TTY-guarded: it takes the NON_INTERACTIVE+GITHUB_TOKEN path, else the /dev/tty path, else `fail "no /dev/tty available..."; exit 1` (setup-identity.sh:90-95) — so it does NOT hang. But that explicit `exit 1` propagates as install rc=1 → engine `exit $rc` aborts the WHOLE run (fail-fast), skipping all later bundles, whenever someone runs `setup.sh --non-interactive` without a GITHUB_TOKEN. That is arguably correct (you asked for identity and can't do it headless), but it's an abrupt whole-run halt on an item that is plausibly optional for non-interactive bootstraps. Worth a guard/skip rather than abort.
- **Fix:** Consider gating this item behind a `when:` (e.g. only when interactive or GITHUB_TOKEN present) so headless runs SKIP it instead of aborting, or have install() detect the no-TTY/no-token case and return a 'skip' that check()/verify() agrees with (so post-verify won't rc67). Keep the hard-fail only when identity is explicitly required.

#### `topics/shell-terminal/wsl/install-atuin.sh` :5-9 — _interactive-no-guard_ · **Wave 4**
atuin install() branches on `[[ -t 0 ]]` instead of the engine's exported NON_INTERACTIVE, so `setup.sh --non-interactive` on a TTY still runs the interactive installer variant

- **What/why:** setup.sh and the engine export NON_INTERACTIVE=1 (setup.sh:49, install-engine.sh:88). install-atuin chooses the `--non-interactive` upstream flag only when stdin is not a TTY (`[[ -t 0 ]]`). Under `setup.sh --non-interactive` run from a terminal, stdin is still a TTY, so it pipes the installer WITHOUT `--non-interactive`, ignoring the explicit operator intent. The upstream atuin installer does not actually prompt, so impact is low — but the guard is the wrong signal.
- **Fix:** Gate on the engine flag too: `if [[ "${NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then ... --non-interactive; else ...; fi`.

#### `topics/web/mac/launchdaemon-hardening.sh` :37, 41, 44-45, 47-48, 60-61 — _interactive-no-guard_ · **Wave 4**
First sudo call (`sudo mkdir`) has no sudo-cache prime / TTY guard

- **What/why:** Unlike valet.sh, mkcert.sh and nginx-sites.sh (which all run `sudo -v 2>/dev/null || true` before sudo work), this install() jumps straight to `sudo mkdir -p /var/log/homebrew` (line 37) and many subsequent `sudo` calls. Under `setup.sh --non-interactive` with no cached sudo credential and no TTY, the first `sudo mkdir` will fail (or block waiting for a password if a TTY is attached but no cache). Because the engine memory rule documents a sudo-cache fallback, this is low severity, but it is an inconsistency with the sibling scripts and can produce a confusing mid-run abort.
- **Fix:** Add `sudo -v 2>/dev/null || true` (or a `_has_tty`/sudo-cache guard) at the top of install(), matching valet.sh/mkcert.sh/nginx-sites.sh.

#### `topics/ai/moshi-hook-service-mac.sh` :67-69, 1-9 — _other_ · **Wave 4**
Uses info()/followup() without sourcing log.sh — works only by inheriting engine functions; brittle outside the engine (WSL counterparts source log.sh defensively)

- **What/why:** install() calls `info` (67) and `followup` (69), but unlike moshi-hook-service-wsl.sh / install-moshi-hook.sh this file never `source`s scripts/lib/log.sh. It works under the engine only because the engine sources log.sh at top level (install-engine.sh:70) and shell functions are inherited into the per-item subshell (verified). If this script is sourced/run by anything that does not pre-load log.sh (a standalone test harness, a future topic-level verify runner), `info`/`followup` resolve to 'command not found'. `info` is unguarded; a failing `info` mid-install would not abort here, but it is an undeclared dependency and an inconsistency with the WSL siblings.
- **Fix:** Source log.sh defensively at the top like the WSL scripts: resolve ws_dir then `. "$ws_dir/scripts/lib/log.sh"` (guarded by the lib's load-once flag), so the script is self-contained regardless of caller.

#### `topics/foundation/verify.sh` :1-25 — _other_ · **Wave 4**
Topic-level standalone verify script, not a custom-item driver — note the distinction

- **What/why:** This file is NOT a custom-item script (it is not referenced by any manifest `script:` field — the foundation manifest only wires mac/core.sh and wsl/core.sh). It runs `set -euo pipefail` at top level and executes a loop immediately when sourced/run, so it must be EXECUTED standalone, never SOURCED by the custom driver (sourcing it would run its top-level loop and could call `exit 1` inside the engine subshell). Its internal `check()` is a print-helper, not the contract check(). As a standalone topic verify it is correct: it checks git/curl/wget/jq/unzip/envsubst/gpg via `command -v` and exits 1 if any missing. `envsubst` (keg-only gettext on mac) and the others are now on the engine PATH per the brew-prefix prepend, but this script runs in whatever context the topic invokes it (likely a login-ish shell), so it is fine. No engine-flow bug; flagged only to record that it is a different kind of script than the rest of the batch.
- **Fix:** No change required. If this is ever wired as a custom item, rename its print-helper away from `check` and guard the top-level loop behind a `main` invocation so sourcing is side-effect-free.

#### `topics/git/gitconfig-apply.sh` :95-110 — _weak-or-missing-verify_ · **Wave 4**
verify() returns 0 after asserting only the FIRST applicable key (masked: item is idempotent so verify never runs)

- **What/why:** verify() loops over data/gitconfig.keys but has an unconditional `return 0` at line 108 inside the loop body, immediately after asserting the first non-comment, non-user.*/credential.* key. Any key after the first is never verified, so a partial apply (key 1 correct, key 2 failed) reports success — the exact 'partial apply' failure the comment (lines 83-90) claims to have fixed. NOTE: in the manifest this item is `idempotent: true` (topics/git/manifest.yaml:34), so the engine SKIPS post-verify entirely (install-engine.sh:602-615) — verify() is dead code on the normal path. Hence low severity. It would only bite if the item were ever flipped to non-idempotent, or if verify() is reused by other tooling.
- **Fix:** Drop the early `return 0` at line 108 so the loop asserts every applicable key, mirroring _apply_keys; only `return 0` after the full loop completes (the trailing `return 0` at line 110 already covers the all-pass case).

#### `topics/shell-terminal/clone-catppuccin.sh` :30-34 — _weak-or-missing-verify_ · **Wave 4**
install() clones default branch then pins by tag in check(); a partial/non-git pre-existing dir aborts the clone under set -e

- **What/why:** Strong check() (asserts origin matches catppuccin/tmux AND v1.0.3 tag points at HEAD) — good, fixes the prior over-accepting check. install() clones with `--branch v1.0.3` into $HOME/.tmux/plugins/tmux. Same partial-dir caveat as the other clones: if the path exists non-git, `git clone` fails under inherited `set -e`; rollback() rm -rf's $CATP_TMUX so it self-heals. No path-fragility (git is managed). check/verify symmetric with what install establishes. Low only for the recoverable first-run failure window on a dirty pre-existing path.
- **Fix:** Optionally pre-clear $CATP_TMUX in install() before clone (it is the managed target and rollback already owns its removal).

#### `topics/syncthing/syncthing-service-mac.sh` :38-60 — _weak-or-missing-verify_ · **Wave 4**
install() returns 1 (whole-run abort) if the UI is not on :8384 within 20s even though the service may have started correctly

- **What/why:** This item is non-idempotent, so an install() non-zero rc triggers rollback + engine `exit $_install_rc` = whole-run abort (install-engine.sh:633-636). After `brew services start` / wrapper install succeeds, install() polls :8384 for 20s (L54-57); if the GUI hasn't bound the port yet (cold start, slow disk, TCC prompt pending on the wrapper path) it returns 1 (L59) and aborts the entire run, discarding a service that is in fact coming up. verify()=_is_running (L62-64) is more lenient (also accepts pgrep / brew-services-started / launchd-running), so the install-time gate is stricter than the verifier. Low severity because 20s is usually enough and the rollback is non-destructive, but on a loaded machine this can spuriously abort later bundles.
- **Fix:** Let install() succeed once the service is registered/running per _is_running rather than hard-requiring the HTTP probe; emit the ':8384 not up yet' message as a warning and `return 0`, leaving the authoritative pass/fail to verify() (which already accepts the broader running states).


## 6 · Clean files (38 — no action)

`/Volumes/External/code/mesh-workstation/topics/git/link-lazygit-config.sh`, `/Volumes/External/code/mesh-workstation/topics/git/verify.sh`, `/Volumes/External/code/mesh-workstation/topics/identity/install-gh-wsl.sh`, `topics/containers/post-setup-wsl.sh`, `topics/databases/mssql-driver.sh`, `topics/databases/wsl/mysql.sh`, `topics/databases/wsl/redis.sh`, `topics/foundation/mac/core.sh`, `topics/foundation/wsl/core.sh`, `topics/git/gpg-signing.sh`, `topics/languages/verify.sh`, `topics/personal/apply.sh`, `topics/remote-access/enable-remote-login.sh`, `topics/remote-access/install-tailscale-mac.sh`, `topics/remote-access/mosh-path-fix.sh`, `topics/remote-access/tailscale-mtu-fix-wsl.sh`, `topics/remote-access/verify.sh`, `topics/shell-terminal/bat-catppuccin-theme.sh`, `topics/shell-terminal/clone-tpm.sh`, `topics/shell-terminal/drift-cleanup.sh`, `topics/shell-terminal/generate-completions.sh`, `topics/shell-terminal/install-zinit.sh`, `topics/shell-terminal/link-nvim-config.sh`, `topics/shell-terminal/link-shipped-configs.sh`, `topics/shell-terminal/mac/iterm2-font.sh`, `topics/shell-terminal/shell-bootstrap.sh`, `topics/shell-terminal/verify.sh`, `topics/shell-terminal/wsl/install-lazygit.sh`, `topics/shell-terminal/wsl/windows-terminal-config.sh`, `topics/shell-terminal/zinit-drift-cleanup.sh`, `topics/shell-terminal/zsh-default-shell.sh`, `topics/syncthing/post-install-banner.sh`, `topics/web/extras/mailpit.sh`, `topics/web/extras/ngrok.sh`, `topics/web/mac/migrate-legacy-nginx.sh`, `topics/web/verify.sh`, `topics/web/wsl/nginx-sites.sh`, `topics/web/wsl/packages.sh`
