# 05-identity

**Auto-configures per-machine GitHub identity** so private repos (dotfiles)
can be cloned without manual SSH key management.

## What it does

1. **Installs `gh` CLI** (apt on Ubuntu 24.04+, brew on Mac; falls back
   to GitHub's APT repo for older distros).
2. **Installs `wslu` on WSL** — provides `wslview`, which `xdg-open`
   delegates to for opening URLs in the Windows browser. Mac has `open`
   built-in and needs no equivalent.
3. **Authenticates gh** via OAuth device flow — **opens browser** once
   per machine. User approves with an 8-char code on
   [github.com/login/device](https://github.com/login/device).
4. **Configures git credential helper** (`gh auth setup-git`) so HTTPS
   clones Just Work for private repos.
5. **Generates `~/.ssh/id_ed25519`** if missing. No passphrase —
   machine-local identity protected by disk encryption + OS login.
6. **Registers the public key** with GitHub via `gh ssh-key add`.
   Idempotent: compares by fingerprint, skips if already registered.
7. **Smoke-tests** `ssh -T git@github.com`.

## Cross-platform notes

| Concern | Mac | Linux/WSL |
|---|---|---|
| `gh` install | `brew install gh` | `apt install gh` (24.04+) or GitHub APT repo |
| Browser opener | `open` built-in | needs `wslu` on WSL; `xdg-open` on native Linux |
| `/dev/tty` | POSIX — works | POSIX — works |
| Token storage | macOS Keychain (transparent) | `~/.config/gh/hosts.yml` (0600) |
| `gh ssh-key add` | identical API | identical API |

### Critical fixes (from testing)

- **`--git-protocol https`** (not `ssh`): prevents `gh auth login` from
  offering to auto-generate a second SSH key. Our script manages the
  key explicitly.
- **`</dev/tty >/dev/tty 2>&1`** redirect: bootstrap.sh invokes topics
  via `tee` pipe, which kills TTY detection in `gh`. The redirect
  bypasses the pipe for the auth command specifically, so `gh` sees a
  real terminal and behaves interactively (with "Press Enter to open
  browser" pause instead of immediate polling).

Both fixes live in `scripts/setup-identity.sh`; cross-platform by design.

## Why per-machine tokens (not one shared PAT)

Each machine gets its own OAuth token + its own SSH key. Advantages:

- **Compromise isolation** — a stolen token from one laptop is revokable
  without affecting the others.
- **Audit clarity** — GitHub shows which machine made each action.
- **No secret copying** — nothing to transfer from your password manager
  to the new machine.

Trade-off: ~30 seconds of browser interaction on each new machine (click
approve + paste code). Alternative is a pre-created PAT stored in a
password manager — the `GITHUB_TOKEN` env var enables that path for CI
(`NON_INTERACTIVE=1 GITHUB_TOKEN=ghp_... bash bootstrap.sh`).

## Ordering

Placed at **05** so it runs:
- After `00-core` (needs `git`, `curl`, `ca-certificates` already present)
- Before `95-dotfiles-personal` (so the private dotfiles clone succeeds)
- Before topics that push to private repos (e.g. `80-claude-code`
  Syncthing state on private repos, if any)

## Re-run behavior

Every step is idempotent:
- `gh auth status` → skip auth if already logged in
- key fingerprint check → skip registration if already on GitHub
- SSH key already present → no regenerate

Safe to re-run as part of a full bootstrap.

## Manual revocation

If a machine is lost or compromised:

```bash
# On any working machine:
gh auth logout --hostname github.com   # kills the oauth token
gh ssh-key list                        # find the stolen machine's key
gh ssh-key delete <key-id>             # deregister it
```

Or at [github.com/settings/applications](https://github.com/settings/applications)
(OAuth) and [github.com/settings/keys](https://github.com/settings/keys) (SSH).

## NON_INTERACTIVE mode

For CI / headless setups, set `GITHUB_TOKEN` to a PAT with
`admin:public_key,repo` scopes:

```bash
NON_INTERACTIVE=1 GITHUB_TOKEN=ghp_... bash bootstrap.sh
```

The topic detects both vars and uses `gh auth login --with-token`
(no browser).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `gh auth login` opens a browser but the machine is headless | Copy the printed URL + code to any browser (phone works) |
| `gh ssh-key add` fails with 403 | Token lacks `admin:public_key` scope. Run `gh auth refresh -s admin:public_key` and re-run this topic |
| `ssh -T git@github.com` still fails after registration | Wait ~10s for GitHub to index the new key, then retry |
| On older Ubuntu, `apt-cache show gh` empty | Script auto-adds GitHub's APT repo fallback |
