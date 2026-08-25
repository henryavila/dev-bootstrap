# WSL / --no-mesh bootstrap

Learnings from a virgin Ubuntu-24.04 install used to validate guest/server mode.

## Operator rule

Do not repair a live WSL by editing rc files or installing packages by hand. Re-apply via `setup.sh` / `--bundle` so the scripts themselves are proven to heal a broken box.

## Login shell

WSL default after `shell-terminal/zsh` is **zsh** (`chsh` to `/usr/bin/zsh`). Windows Terminal starts `wsl.exe -d Ubuntu-24.04` with no explicit shell, so it uses passwd. Bash stays configured (`~/.bashrc.d`, starship) as fallback. `docs/SPEC.md` still says “WSL: default shell = bash”; that line is stale versus the engine.

## Prompt (`ULTRON%`)

Stock zsh `%m%#` means p10k never loaded. zinit/p10k clones lived on disk but wiring was assumed in identity `~/.zshrc.local`, which `--no-mesh` omits. Fix: deploy `~/.zshrc.d/90-prompt.sh` from `shell-terminal` (theme + `~/.p10k.zsh` + autosuggestions/syntax/fzf-tab). `~/.zshrc` must also source `*.zsh` so `auto-update.zsh` / `mesh-guard.zsh` load (glob was `*.sh` only).

p10k does not rewrite `PS1` on a non-TTY (`zsh -lic` in a pipe). Probe `whence p10k` / functions, not `PS1=%m%#`.

## Auto-update on every zsh login

Sourcing `*.zsh` started `auto-update.sh --from-shell-start`. `persist_code_dir` writes `~/.config/mesh/config.env` with only `CODE_DIR`; that file is treated as `CONF`. Under `set -u`, `${#AUTO_UPDATE_REPOS[@]}` crashes if the array was never declared.

- Shell-start: missing conf or empty/unset `AUTO_UPDATE_REPOS` → exit 0, no noise.
- Manual `mesh update`: still fail-closed with “AUTO_UPDATE_REPOS is empty”.
- Same `set -u` empty-array pattern already used for `AUTO_UPDATE_RELOAD` (`${arr[@]+...}`).

## Sudo warmup hang

`sudo -v` on a WSL pts with the user in `%sudo` (password required) waits forever even when a later `NOPASSWD:ALL` exists (`verifypw=all`). `NON_INTERACTIVE` / non-TTY must use `sudo -n -v`. Real `sudo apt` still matches NOPASSWD. Do not name a test sudoers file `10-${USER}-nopasswd` — setup deletes that path as a legacy leftover.

## PHP 8.4 PPA

`add-apt-repository ppa:ondrej/php` uses launchpadlib → `api.launchpad.net` (often firewalled/timeout). Archive `ppa.launchpadcontent.net` and the keyserver can still work. Cap `add-apt-repository` and fall back to a `signed-by` source file.

## mkcert → Windows Root

Do not pass `\\wsl.localhost\...` into powershell spawned *from* WSL (9P reentry deadlock). Copy CA + importer onto `%TEMP%`. Windows-side fallback: `wsl.exe cp` onto `/mnt/c/...`, not `wsl cat` (UTF-16). PowerShell 5.1: a one-distro `wsl -l` split is a string; `[0].Trim()` is `[char]` → wrap splits in `@()`. `Import-Certificate` to `CurrentUser\Root` always shows the Protected Roots dialog; registry writes get deleted. Run the importer from an interactive, **non-elevated** Windows Terminal and click Sim.

## Starship

Upstream installer defaults to `/usr/local/bin` and blocks on sudo even with `--yes`. Install with `--bin-dir "$HOME/.local/bin"`. zsh must not `eval "$(starship init zsh)"` — p10k owns the prompt.

## `--bundle` vs lean selection

`--bundle` rebuilds `selections.list`. A web-only apply drops zsh/fonts/node from the list (does not uninstall). Re-apply lean bundles explicitly if those should stay selected.
