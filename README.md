# dev-bootstrap

[![smoke-test](https://github.com/henryavila/dev-bootstrap/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/henryavila/dev-bootstrap/actions/workflows/smoke-test.yml)
[![lint](https://github.com/henryavila/dev-bootstrap/actions/workflows/lint.yml/badge.svg)](https://github.com/henryavila/dev-bootstrap/actions/workflows/lint.yml)

Reproducible dev-machine setup for WSL2/Ubuntu, macOS, and Windows (via WSL).

> **Languages:** English (this file) · [Português](README.pt-BR.md)

One of three repos in a layered architecture:

| Repo | Role | Visibility |
|------|------|------------|
| **dev-bootstrap** (this) | Installs tools and applies opinionated global configs | public |
| [dotfiles-template](https://github.com/henryavila/dotfiles-template) | Skeleton for personal dotfiles (`.example` files + `install.sh`) | public (GitHub template) |
| `<user>/dotfiles` | Personal dotfiles, derived from the template via *Use this template* | **private** (per user) |

**Separation of concerns:** the bootstrap installs CLI/daemons/stack and writes universal configs (bashrc, inputrc, global gitconfig, fragments in `~/.bashrc.d/`); personal dotfiles apply identity + overrides on top.

## Quickstart

### Windows (before WSL)

PowerShell **as Administrator**:

```powershell
git clone https://github.com/henryavila/dev-bootstrap "$env:USERPROFILE\dev-bootstrap"
cd "$env:USERPROFILE\dev-bootstrap"
.\windows\install-wsl.ps1
```

Restart, open the freshly-installed Ubuntu, and follow the WSL instructions below.

### WSL2/Ubuntu or macOS

**Interactive mode (default):**

```bash
git clone https://github.com/henryavila/dev-bootstrap ~/dev-bootstrap
cd ~/dev-bootstrap
bash bootstrap.sh
```

Running without any control env var opens a `whiptail` menu that asks:

1. Which opt-in topics to enable (`60-laravel-stack` / `70-remote-access` / `90-editor` / `95-dotfiles-personal` — all pre-checked by default; deselect what you don't want).
2. `GIT_NAME` / `GIT_EMAIL` (skipped silently when `git config --global` already has them).
3. `DOTFILES_REPO` + `DOTFILES_DIR` (only when `95-dotfiles-personal` is checked).
4. `CODE_DIR` (only when `60-laravel-stack` is checked).
5. Final confirmation with a summary — cancelling at any screen aborts cleanly (no partial state).

If `whiptail` isn't installed, the bootstrap installs it first (`apt install whiptail` on Linux/WSL; `brew install newt` on Mac — whiptail ships inside the `newt` formula).

**Automation / CI mode** (no menu — env vars and flags):

```bash
# preview the plan without executing
bash bootstrap.sh --dry-run

# skip the menu even on a TTY
NON_INTERACTIVE=1 bash bootstrap.sh
bash bootstrap.sh --non-interactive

# run specific topics only
ONLY_TOPICS="00-core 10-languages" bash bootstrap.sh

# enable opt-in topics
INCLUDE_LARAVEL=1 INCLUDE_REMOTE=1 bash bootstrap.sh

# pull personal dotfiles at the end
DOTFILES_REPO=git@github.com:you/dotfiles.git bash bootstrap.sh
```

The menu is automatically skipped when any of these is true: (a) `NON_INTERACTIVE=1` or `--non-interactive`; (b) any control var (`INCLUDE_*`, `DOTFILES_REPO`, `ONLY_TOPICS`, `CI`) is already set; (c) stdin/stdout isn't a TTY (pipe, cron, CI).

Right after the menu (or immediately, when skipped), the bootstrap runs `sudo -v` to warm up the sudo cache — one password prompt, then subsequent `sudo` calls within the cache window (~5–15min) are silent.

## Topics

| Topic | Installs / applies | Opt-in |
|-------|--------------------|--------|
| `00-core` | git, curl, build-essential, jq, unzip, envsubst (gettext) | — |
| `10-languages` | Node via fnm + LTS, PHP 8.4 (ondrej ppa / brew), Python 3 | — |
| `20-terminal-ux` | fzf, bat, eza, zoxide, ripgrep, fd, starship (Catppuccin Mocha), lazygit, delta + Nerd Font CaskaydiaCove | — |
| `30-shell` | `~/.bashrc` / `~/.zshrc` loaders + `~/.inputrc` (word-kill, completion niceties) | — |
| `40-tmux` | tmux + `~/.tmux.conf` (prefix `Ctrl+a`) | — |
| `50-git` | opinionated global gitconfig (delta, zdiff3, aliases) + `~/.bashrc.d/50-git.sh` with aliases `g` / `gs` / `gco` / `whoops` / `gmm` + `__git_complete` | — |
| `60-laravel-stack` | **MySQL 8** (`mysql-server-8.0` WSL / `mysql@8.0` Mac), Redis, Nginx, PHP-FPM, mkcert, `*.localhost` catchall | `INCLUDE_LARAVEL=1` |
| `70-remote-access` | sshd (hardening via `sshd_config.d/99-${USER}.conf`), Tailscale, mosh + systemd drop-in setting MTU 1200 on `tailscale0` (prevents SSH KEX PQ hang) | `INCLUDE_REMOTE=1` |
| `80-claude-code` | Claude Code CLI + **Syncthing daemon** (P2P sync) — foundation for cross-machine Claude Sync via the dotfiles layer | — |
| `90-editor` | `~/.local/bin/typora-wait` — opens `.md` files in the Typora GUI from the terminal; WSL delegates to `Typora.exe` via interop (`wslpath -w`), macOS uses `open -W -a Typora` (LaunchServices) | `INCLUDE_EDITOR=1` |
| `95-dotfiles-personal` | clones `$DOTFILES_REPO` into `$DOTFILES_DIR` (default `~/dotfiles`) + runs its `install.sh` | `DOTFILES_REPO=<url>` |

Every topic has its own `README.md`. Internal flow: `install.$OS.sh` (if present) or `install.sh` (OS-agnostic fallback), then `lib/deploy.sh` processes `templates/` when applicable. Templates named `bashrc.d-<topic>.sh` / `zshrc.d-<topic>.sh` map automatically to `~/.bashrc.d/<topic>.sh` / `~/.zshrc.d/<topic>.sh`.

## Env vars and CLI flags

Primarily for automation / CI — the interactive menu fills these in for human use. Any pre-existing env var wins over menu defaults.

| Var / flag | Effect |
|------------|--------|
| `--non-interactive` / `NON_INTERACTIVE=1` | Skip the menu even on a TTY |
| `--dry-run` / `DRY_RUN=1` | Print what would run without executing (also skips `sudo -v`) |
| `--help` / `-h` | Usage message |
| `SKIP_TOPICS` | space-separated list of topics to skip |
| `ONLY_TOPICS` | run only these topics |
| `DOTFILES_REPO` | URL/path of the personal dotfiles repo (accepts `file://` for local testing) |
| `DOTFILES_DIR` | clone destination (default `~/dotfiles`) |
| `GIT_NAME` / `GIT_EMAIL` | identity — applied only when `user.name` / `user.email` aren't set yet (topic 50-git preserves existing values) |
| `CODE_DIR` | projects root (default `~/code/web`) |
| `INCLUDE_LARAVEL` / `INCLUDE_REMOTE` / `INCLUDE_EDITOR` | enable opt-in topics |
| `NO_COLOR=1` | disable colored output (auto when not a TTY) |

## MySQL 8 notes

- **WSL**: installs `mysql-server-8.0` explicitly — not the meta `mysql-server` package, which can resolve to MariaDB on some Debian derivatives.
- **Mac**: brew formula `mysql@8.0` (the default `mysql` formula tracks 9.x). Because `mysql@8.0` is keg-only, the installer runs `brew link --force --overwrite mysql@8.0` so `mysql` / `mysqladmin` / `mysqldump` end up on `$PATH`.
- **Mac escape hatch**: if `brew install mysql@8.0` fails for any reason, install via Oracle's [DMG installer](https://dev.mysql.com/downloads/mysql/) (it drops binaries in `/usr/local/mysql`). The bootstrap detects that path and skips brew automatically.

## Logs

Full output of every run is written to `/tmp/dev-bootstrap-<os>-<timestamp>.log`. The bootstrap prints the path near the top.

## Project structure

```
dev-bootstrap/
├── bootstrap.sh              # runner — OS detection, interactive menu, sudo warmup, topic orchestration
├── lib/                      # detect-os.sh, detect-brew.sh, deploy.sh, log.sh, menu.sh
├── topics/NN-<name>/         # idempotent installation units
│   ├── install.$OS.sh        # WSL or Mac
│   ├── templates/            # files deployed via lib/deploy.sh
│   ├── verify.sh             # non-destructive check
│   └── README.md             # per-topic docs
├── windows/install-wsl.ps1   # Windows bootstrap → WSL2 + Nerd Font
├── docs/SPEC.md              # technical specification
└── .github/workflows/        # CI
```

## Releases

| Tag | Highlights |
|-----|------------|
| `v2026-04-19` | Enriched `~/.inputrc` (word-kill, completion niceties) + new `topics/50-git/templates/bashrc.d-50-git.sh` with aliases `g`/`gs`/`gco`/`whoops`/`gmm` + `__git_complete` (bash). |
| `v2026-04-20` | Topic `80-claude-code` split into `install.wsl.sh` / `install.mac.sh`; **installs Syncthing daemon** for cross-machine Claude Sync (the `claude/` folder in dotfiles-template uses `.stignore` to control what replicates). |
| `v2026-04-21` | Topic `70-remote-access` automates the Tailscale MTU fix via drop-in `/etc/systemd/system/tailscaled.service.d/mtu.conf` (Linux). Mac ships an on-demand `scripts/mac-tailscale-mtu-fix.sh`. Hotfixes: starship TOML scope bug fix, `sudo -v` warmup on bootstrap start, removal of legacy `/etc/sudoers.d/10-${USER}-nopasswd`. |
| `v2026-04-22` | **Interactive whiptail menu is the new default** (opt-in topic selection + git identity + paths); `--non-interactive` and `--dry-run` CLI flags. MySQL 8 pinned explicitly (`mysql-server-8.0` WSL / `mysql@8.0` Mac) with Oracle DMG escape hatch. Topic `90-editor` repositioned: `typora-wait` handles WSL→Windows Typora via `wslpath -w` interop and uses `open -W -a Typora` on macOS (LaunchServices-based discovery). |

### Release discipline

Structural changes (new topic, changes in `lib/`, `install.sh`, `bootstrap.sh`) go through:

1. Commit with a **migration note** in the body — *forks that already ran X should Y*. Estimated time, affected files, command to apply.
2. Dated tag: `git tag -a v2026-MM-DD -m "summary"`.
3. `gh release create v2026-MM-DD --notes-from-tag` after pushing.

Hotfixes with no structural change (template bug, README typo) use regular commits without a tag.

## CI

- `.github/workflows/lint.yml` (Tier 1) — shellcheck + `bash -n` on every push/PR.
- `.github/workflows/integration.yml` (Tier 2, planned for v1.1) — runs `bootstrap.sh` against a matrix of `ubuntu-22.04`, `ubuntu-24.04`, `macos-latest`, validates idempotency (2nd run = noop), and executes each topic's `verify.sh`.

## Personal dotfiles

This repo **never** versions personal configs (SSH, git identity, project-specific aliases). For that, use [dotfiles-template](https://github.com/henryavila/dotfiles-template): click *Use this template* on GitHub, mark the new repo **private**, and either let the interactive menu collect `DOTFILES_REPO` or set the env var before running `bootstrap.sh`.

## Contributing

1. Adding a new topic: copy the structure of `topics/00-core/`.
2. Idempotency required: a second run must be a no-op (`already installed`, `up to date`). CI enforces this.
3. Before opening a PR: `shellcheck topics/<topic>/*.sh` must pass.

## See also

- [`docs/SPEC.md`](docs/SPEC.md) — technical specification (architecture, acceptance criteria, roadmap).
- [`docs/ALIASES.md`](docs/ALIASES.md) — inventory of universal aliases (shell + git) that every dev who ran the bootstrap receives.
- `topics/<topic>/README.md` — per-topic customization and gotchas.
- [`dotfiles-template`](https://github.com/henryavila/dotfiles-template) — the flip side of the layer: personal overrides.
