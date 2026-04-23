# ALIASES — universal (installed by dev-bootstrap)

Compact list of the aliases **every dev who ran `bootstrap.sh`** receives, regardless of personal dotfiles. Personal dotfiles can add or override (via `~/.bashrc.d/99-personal-aliases.sh` / `~/.zshrc.d/99-personal-aliases.sh` — the `99-` prefix loads them last). For a consolidated inventory including personal ones, see the `docs/ALIASES.md` in that dev's dotfiles repo.

## Sources in this repo

| Fragment | Topic | Contents |
|----------|-------|----------|
| `topics/30-shell/templates/{bash,zsh}rc.d-30-shell.sh.template` | always-on | navigation (`..`, `home`), shell shortcuts (`h`, `c`, `cla`), grep colored, `alert` (Linux desktop notify), `mkd`/`md`/`fs`/`tre` helpers |
| `topics/20-terminal-ux/templates/{bash,zsh}rc.d-20-terminal-ux.sh.template` | always-on | listing (`ls`/`ll`/`la`), view (`cat`→bat), Phase E replacements (`top`→btop, `df`→duf, `du`→dust, `ping`→gping, `http`→xh, `ps`→procs) |
| `topics/40-tmux/templates/{bash,zsh}rc.d-40-tmux.sh` | always-on | tmux shortcuts: `tl` list, `ta` attach, `tn` new, **`tm`** attach-or-create 'main' |
| `topics/50-git/templates/{bash,zsh}rc.d-50-git.sh` | always-on | shell-level git aliases (g/gs/gco…) + autocomplete |
| `topics/60-web-stack/templates/{bash,zsh}rc.d-60-web-stack.sh` | `INCLUDE_WEBSTACK=1` | Laravel (`art`, `artisan`, `cinst`, `migrate`…) + service restart (`srn`, `srp`, `srr`…) |
| `topics/70-remote-access/templates/{bash,zsh}rc.d-70-remote-access.sh` | `INCLUDE_REMOTE=1` | Tailscale (`ts`, `tip`, `tup`, `tping`, `tssh`…) + `tip-of()` function |
| `topics/50-git/data/gitconfig.keys` | always-on | git-level aliases (`git co`, `git st`…) via `git config --global alias.X Y` |

Opt-in fragments (60-web-stack, 70-remote-access) only deploy when the corresponding topic ran. If you ship the bootstrap without Laravel / Tailscale, those fragments aren't installed, their aliases aren't declared.

## 30-shell — navigation + shell basics

| Alias | Expands to | Guard |
|-------|------------|-------|
| `..` / `...` / `....` / `.....` | `cd ..` / `cd ../..` / etc. | — |
| `home` | `cd ~` | — |
| `h` | `history` | — |
| `j` | `jobs` | — |
| `e` | `exit` | — |
| `c` | `clear` | — |
| `cla` | `clear && ls -la` | — |
| `grep` / `fgrep` / `egrep` | `<cmd> --color=auto` | — |
| `alert` | desktop notification when prev cmd finished | `command -v notify-send` (Linux) |

Functions in the same fragment:

| Function | Purpose |
|----------|---------|
| `mkd <dir>` / `md <dir>` | `mkdir -p` + `cd` in one step |
| `fs [paths]` | total size of files or dir contents (prefers GNU `du -b`) |
| `tre [paths]` | `tree` with hidden files, ignoring `.git`/`node_modules`/`vendor`/etc. |

## 20-terminal-ux — listing + view + Phase E

| Alias | Expands to | Guard |
|-------|------------|-------|
| `ls` | `eza` | `command -v eza` |
| `ll` | `eza -l --git` | same |
| `la` | `eza -la --git` | same |
| `cat` | `bat --style=plain --paging=never` | `command -v bat` |
| `bat` | `batcat` | `command -v batcat && ! bat` (Ubuntu) |
| `cat` (Ubuntu fallback) | `batcat --style=plain --paging=never` | same |
| `fd` | `fdfind` | `command -v fdfind && ! fd` (Ubuntu) |

### Phase E — modern CLI replacements

Each block gates on `command -v`, so aliases no-op on machines without the tool (scripts calling the original binary still work):

| Alias | Replaces | Provided by |
|-------|----------|-------------|
| `top` / `htop` | top / htop | `btop` |
| `df` | df | `duf` |
| `du` | du | `dust` |
| `ping` | ping | `gping` |
| `http` | curl/httpie | `xh` |
| `ps` | ps | `procs` |

`tldr` (via `tealdeer`) is intentionally NOT aliased as `man` — full manpages stay valuable.

## 40-tmux — session shortcuts

| Alias | Expands to | Purpose |
|-------|------------|---------|
| `tl` | `tmux ls` | list sessions |
| `ta <name>` | `tmux attach -t` | attach by name |
| `tn <name>` | `tmux new -s` | new session |
| **`tm`** | `tmux new -A -s main` | attach-or-create the canonical 'main' session — `-A` means "behave as attach-session if it exists", so the first call spawns and every subsequent call re-enters |

For project-specific session names (e.g. `th` → "arch", `tsda` → "sda"), add them to your private `~/.bashrc.d/99-personal-aliases.sh`.

## 50-git — shell + git-level

### Shell aliases

| Alias | Expands to |
|-------|------------|
| `g` | `git` |
| `gs` | `git status` |
| `gl` | `git log --oneline --graph --decorate -15` |
| `gd` | `git diff` |
| `gds` | `git diff --staged` |
| `gco` | `git checkout` |
| `gb` | `git branch` |
| `gp` | `git pull` |
| `gaa` | `git add .` |
| `gc` | `git commit` |
| `grb` | `git rebase -i` |
| `gsh` | `git show` |
| `glog` | `git log --oneline --decorate --graph` |
| `gloga` | `git log --oneline --decorate --graph --all` |
| `whoops` | `git reset --hard && git clean -df` ⚠️ destructive |
| `gmm` | switch main + pull + back + merge main — keeps your place |

### Git-level (via global gitconfig)

| Usage | Expands to |
|-------|------------|
| `git co` / `br` / `st` / `ci` / `sw` | checkout / branch / status / commit / switch |
| `git last` | `log -1 HEAD` |
| `git unstage` | `reset HEAD --` |
| `git lg` | `log --oneline --graph --decorate --all` |
| `git amend` | `commit --amend --no-edit` |
| `git undo` | `reset HEAD~1 --mixed` |
| `git df` / `dfc` | `diff` / `diff --cached` |

### Autocomplete (bash-only)

The fragment calls `__git_complete` for `g`, `gco`, `gb`, `gp`, `gd` — Tab autocompletes branches as if you had typed `git`. Requires `bash-completion` (installed by 20-terminal-ux).

Zsh uses stock `compinit` — already resolves completion on aliases automatically.

## 60-web-stack — Laravel + services (opt-in)

Only deployed when `INCLUDE_WEBSTACK=1`.

### Laravel / Composer

| Alias | Expands to |
|-------|------------|
| `art` / `artisan` | `php artisan` |
| `cdump` | `composer dump-autoload -o` |
| `cinst` | `composer install` |
| `cup` | `composer update` |
| `fresh` | `php artisan migrate:fresh` |
| `migrate` / `refresh` / `rollback` | corresponding `migrate:*` |
| `seed` | `php artisan db:seed` |
| `db:reset` | `migrate:reset && migrate --seed` |
| `aserve` | `php artisan serve --quiet &` |
| `dusk` | `php artisan dusk` |
| `phpunit` / `pu` / `puf` / `pud` | `./vendor/bin/phpunit [--filter] [--debug]` |

### Service restart (nginx + PHP-FPM + redis)

PHP version is detected at load time, so `srp`/`ssp` always target the current default PHP.

| Alias | Expands to |
|-------|------------|
| `srn` / `ssn` | nginx restart / status |
| `srp` / `ssp` | php${ver}-fpm restart / status |
| `srr` / `ssr` | redis restart / status |

## 70-remote-access — Tailscale (opt-in)

Only deployed when `INCLUDE_REMOTE=1`. Entire fragment gated on `command -v tailscale` — no-op when not installed.

| Alias / fn | Expands to |
|-----------|-----------|
| `ts` | `tailscale status` |
| `tip` | `tailscale ip -4` |
| `tup` / `tdown` | `sudo tailscale up` / `down` |
| `tnetcheck` | `tailscale netcheck` |
| `tping <host>` | `tailscale ping` |
| `tssh <host>` | `tailscale ssh` (bypasses local sshd — uses mesh key management) |
| `tip-of <hostname>` | Tailscale IP of that host by name |

## How to add a new universal alias

1. Decide scope: nav/shortcuts → 30-shell; listing/view/Phase E → 20-terminal-ux; git → 50-git; Laravel/services → 60-web-stack; Tailscale → 70-remote-access; tmux shortcut → 40-tmux; new category → create a new topic or motivate in the PR.
2. Edit **both** `bashrc.d-<topic>.sh` **and** `zshrc.d-<topic>.sh` for parity.
3. Add a `# shellcheck shell=bash` directive as the first comment line of the zsh fragment (shellcheck can't natively lint zsh).
4. Update this `docs/ALIASES.md`.
5. Add a regression test in `tests/integration/regression-recent-fixes.test.sh` asserting the alias is present.
6. Commit with a migration note.

## Dev-bootstrap release notes on aliases

- `v2026-04-19` — created 50-git fragment with 16 shell-level git aliases + `__git_complete`.
- `2026-04-23` (untagged) — large migration from Henry's private dotfiles to public topics: 30-shell gained navigation + shortcuts + utility funcs; 20-terminal-ux gained Phase E; 40-tmux/60-web-stack/70-remote-access got their first fragments. Rationale: anything not tied to a specific user/path/account belongs in the public baseline so every bootstrap user gets the same DX out of the box.

## Related

- `topics/<topic>/README.md` — per-topic customization and gotchas.
- Each dev's personal dotfiles — add specific aliases under `~/.bashrc.d/99-personal-aliases.sh` (they override these via the `99-` prefix).
