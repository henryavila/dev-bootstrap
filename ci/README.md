# ci/ — local smoke test

Hermetic Docker smoke test for `bootstrap.sh`. Catches regressions before
trying the bootstrap on a real WSL or Mac install.

## Running

```bash
cd ~/dev-bootstrap
bash ci/smoke-test.sh
```

Builds `dev-bootstrap-smoke` from `Dockerfile.ubuntu-24.04`, runs
`bash ~/dev-bootstrap/bootstrap.sh` inside it with `NON_INTERACTIVE=1`
and a curated `SKIP_TOPICS` list, writes the full run log to
`ci/last-run.log`, and prints `SMOKE TEST PASSED` or `SMOKE TEST FAILED`.

Exit codes:

- `0` — all targeted topics installed cleanly
- `124` — hit the 10-minute hard timeout (override with `TIMEOUT_SECS=`)
- `127` — `docker` CLI not on PATH
- any other non-zero — a topic failed; read `ci/last-run.log`

Options:

- `--no-cache` rebuilds the image from scratch (use after editing a
  pre-bootstrap apt package in the Dockerfile)
- `EXTRA_SKIP="..." bash ci/smoke-test.sh` appends topics to the skip list
  (e.g. while bisecting a failure)

## What runs

7 topics are exercised end-to-end:

| Topic            | What it installs                                              |
| ---------------- | ------------------------------------------------------------- |
| `00-core`        | apt essentials: git, curl, jq, gettext-base, build-essential  |
| `10-languages`   | fnm + Node LTS, PHP 8.4 via ondrej PPA, Composer              |
| `20-terminal-ux` | fzf, bat, eza, zoxide, ripgrep, starship, lazygit, git-delta  |
| `30-shell`       | `~/.bashrc.d`, `~/.zshrc.d` scaffolding                       |
| `40-tmux`        | apt tmux + catppuccin-tmux v1.0.3                             |
| `50-git`         | git config from `data/gitconfig.keys` (identity skipped if no env) |
| `80-claude-code` | Bun runtime, Claude Code CLI, Syncthing                       |

## What is skipped and why

Explicit `SKIP_TOPICS` in `smoke-test.sh`:

- **`05-identity`** — `gh auth login --web` expects an interactive TTY for
  the OAuth device-code flow. No clean way to drive that without mocking
  the `gh` binary.
- **`95-dotfiles-personal`** — clones a private repo over SSH. We'd need
  to mount a credentialed key into the container; out of scope.

Auto-skipped by the bootstrap's own opt-in gates (we deliberately leave
these OFF the explicit list so the gate logic itself is exercised):

- **`60-laravel-stack`** — gated by `INCLUDE_LARAVEL=1`
- **`70-remote-access`** — gated by `INCLUDE_REMOTE=1`
- **`90-editor`** — gated by `INCLUDE_EDITOR=1`

## Image design

`Dockerfile.ubuntu-24.04` is intentionally close to a fresh WSL Ubuntu install:

- non-root `henry` user with NOPASSWD sudo (container ergonomics only)
- **Phase 0** of `docs/onboard-new-machine.md` pre-installed: `git curl ca-certificates`
- plus `sudo`, `locales`, `tzdata`, `software-properties-common` — these
  ship by default in WSL's Ubuntu cloud image but are missing from
  `ubuntu:24.04`'s minimal base. Pre-installing them here means the
  smoke test focuses on bootstrap regressions, not base-image drift.

### `ALLOW_OVERWRITE_UNMANAGED=1`

The bootstrap refuses to overwrite existing config files (`~/.bashrc`,
`~/.zshrc`, etc.) that don't carry the `managed by dev-bootstrap` marker —
protection against clobbering hand-maintained configs on a real user's
machine. Inside the smoke container the home directory is seeded from
`/etc/skel` when `useradd` runs, so those files exist without the marker
and 30-shell would fail on first deploy. Setting
`ALLOW_OVERWRITE_UNMANAGED=1` in `smoke-test.sh`'s invocation bypasses the
check for CI only. A `.bak-<ts>` is still written by the bootstrap before
the overwrite; you can inspect it in the container's stdout.

### The `detect-os.sh` coercion

`lib/detect-os.sh` decides `wsl` vs `linux` by grepping `/proc/version`
for `microsoft`. Inside Docker, `/proc/version` shows the host kernel (no
`microsoft`) so it would report `linux` — and 5 of the 7 targeted topics
only ship `install.wsl.sh`/`install.mac.sh`, no generic `install.sh`.
Without help they'd silently skip as "no installer", making the whole
test green and meaningless.

The Dockerfile patches **only the image's copy** of `lib/detect-os.sh` to
grep `/etc/fake-proc-version` (a file we own, containing the magic
`microsoft` substring) instead of `/proc/version`. Upstream `lib/` on
disk is untouched. A sanity check at the end of the `RUN` verifies the
patched script now outputs `wsl`.

## Adding 05-identity coverage (future work)

`gh auth login --web` is the blocker. Options if the need arises:

1. **Mock `gh`** — drop a fake binary earlier in `PATH` that records the
   call and returns success. Loses coverage of the real CLI.
2. **PAT mode** — pass a `GITHUB_TOKEN` and run
   `gh auth login --with-token <<< "$GITHUB_TOKEN"`. No TTY needed, but
   requires a secret store; overkill for local runs, worth it for GitHub
   Actions.
3. **Partial coverage** — split `setup-identity.sh` so the SSH-key-gen and
   `~/.ssh/config` writes can run independently of `gh auth login`, and
   smoke-test only that half.

None of these is obviously worth doing until a 05-identity regression
actually bites.

## Known flaky surfaces

A clean Docker run has full internet access, so these generally work.
Behind a restrictive proxy / air-gapped runner / flaky DNS they can fail
non-deterministically — if you see one of these topics fail, check
`ci/last-run.log` for the curl/wget error before assuming it's a
bootstrap regression.

| Topic            | Risky network hop                                         |
| ---------------- | --------------------------------------------------------- |
| `10-languages`   | `fnm.vercel.app/install` (bash pipe), `ppa.launchpadcontent.net` (ondrej/php), `getcomposer.org`, `composer.github.io` |
| `20-terminal-ux` | GitHub releases for dust/xh/procs (native-Linux branch)   |
| `40-tmux`        | `github.com/catppuccin/tmux` (shallow clone)              |
| `80-claude-code` | `bun.sh/install` (bash pipe), `claude.ai/install.sh` (bash pipe) |

If a topic fails on a repeat run for transient network reasons, add it
to `EXTRA_SKIP` temporarily:

```bash
EXTRA_SKIP="80-claude-code" bash ci/smoke-test.sh
```

Permanent additions belong in the default `SKIP_TOPICS` list in
`smoke-test.sh` with a comment explaining why.

## Known divergences from a real WSL install

These intentional simplifications mean the smoke test is necessary but
not sufficient — manual validation on a real WSL instance still matters:

- no `systemd` / `systemctl` (container lacks PID 1 systemd). Topics that
  enable services (`syncthing`) are validated as "installed", not "running".
- no Windows-side interop (`clip.exe`, `wslpath`). Anything gated on WSL
  interop bridges is either skipped or takes the non-WSL branch.
- no real `gh` OAuth (see above).
- the test runs as `henry` specifically; the bootstrap has some
  `$USER`-sensitive paths that would diverge under a different account.
