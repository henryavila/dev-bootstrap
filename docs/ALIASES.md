# ALIASES — universal (installed by mesh-workstation)

Compact list of the aliases **every dev who ran `setup.sh`** receives, regardless of personal dotfiles. Personal dotfiles can add or override (via `~/.bashrc.d/99-personal-aliases.sh` / `~/.zshrc.d/99-personal-aliases.sh` — the `99-` prefix loads them last). For a consolidated inventory including personal ones, see the `docs/ALIASES.md` in that dev's dotfiles repo.

Fragments deploy when the owning **Blink / `--bundle` / `selections.list`**
selection installed that bundle (legacy `INCLUDE_*=1` env gates are not the
user-facing activation path).

## Sources in this repo

| Fragment | Bundle | Contents |
|----------|--------|----------|
| `topics/shell-terminal/templates/zsh/{bash,zsh}rc.d-30-shell.sh.template` | `shell-terminal/zsh` | navigation (`..`, `home`), shell shortcuts (`h`, `c`, `cla`), grep colored, `alert` (Linux desktop notify), `mkd`/`md`/`fs`/`tre` helpers |
| `topics/shell-terminal/templates/cli-tools/{bash,zsh}rc.d-20-terminal-ux.sh.template` | `shell-terminal/cli-tools` | listing (`ls`/`ll`/`la`), view (`cat`→bat), Phase E replacements (`top`→btop, `df`→duf, `du`→dust, `ping`→gping, `http`→xh, `ps`→procs) |
| `topics/shell-terminal/templates/tmux/{bash,zsh}rc.d-40-tmux.sh` | `shell-terminal/tmux` | tmux shortcuts: `tl` list, `ta` attach, `tn` new, **`tm`** go to 'main' without nesting |
| `topics/git/templates/config/{bash,zsh}rc.d-50-git.sh` | `git/config` | shell-level git aliases (g/gs/gco…) + autocomplete |
| `topics/web/templates/serve/{bash,zsh}rc.d-60-web-stack.sh` | `web/valet` or `web/nginx-php-fpm` | Laravel (`art`, `artisan`, `cinst`, `migrate`…) + service restart (`srn`, `srp`, `srr`…) |
| `topics/remote-access/templates/tailscale/{bash,zsh}rc.d-70-remote-access.sh` | `remote-access/tailscale` | Tailscale (`ts`, `tip`, `tup`, `tping`, `tssh`…) + `tip-of()` function |
| `topics/git/data/gitconfig.keys` | `git/config` | git-level aliases (`git co`, `git st`…) via `git config --global alias.X Y` |

Opt-in fragments (web serve, Tailscale) only deploy when the corresponding
bundle was selected. Without Laravel / Tailscale in the selection, those
fragments aren't installed and their aliases aren't declared.

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
| `ta <name>` | Outside tmux: `tmux attach -t`; inside tmux: `tmux switch-client -t` | attach/switch by name without nesting tmux clients |
| `tn <name>` | `tmux new -s` | new session |
| **`tm`** | Outside tmux: `tmux new-session -A -s main`; inside tmux: `tmux switch-client -t main` after creating `main` detached if needed | go to the canonical `main` session without nesting tmux clients |
| `tmux_project <session> <dir>` | Outside tmux: attach/create with `-c <dir>`; inside tmux: switch/create detached first | reusable helper for private project shortcuts without nested tmux clients |

For project-specific session names (e.g. `th` → "arch", `tsda` → "sda"), add thin wrappers in your private `~/.bashrc.d/99-personal-aliases.sh` that call `tmux_project`.

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
| `gps` | `git push` |
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

The fragment calls `__git_complete` for `g`, `gco`, `gb`, `gp`, `gps`, `gd` — Tab autocompletes branches/remotes as if you had typed `git`. Requires `bash-completion` (installed by 20-terminal-ux).

Zsh uses stock `compinit` — already resolves completion on aliases automatically.

## web serve — Laravel + services (opt-in)

Only deployed when a web serve bundle (`web/valet` or `web/nginx-php-fpm`) was
selected in Blink / `--bundle` / `selections.list`.

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

## remote-access/tailscale — Tailscale (opt-in; `membership: mesh`)

Only deployed when `remote-access/tailscale` was selected (omitted under
`--no-mesh`). Entire fragment gated on `command -v tailscale` — no-op when not
installed.

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

1. Decide scope: nav/shortcuts → `shell-terminal/zsh`; listing/view/Phase E → `shell-terminal/cli-tools`; git → `git/config`; Laravel/services → `web/*` serve templates; Tailscale → `remote-access/tailscale`; tmux → `shell-terminal/tmux`; new category → new bundle or motivate in the PR.
2. Edit **both** bash and zsh fragments under the live `topics/<id>/templates/…` path for parity.
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
