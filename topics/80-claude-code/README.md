# 80-claude-code

Installs the two tools that make up the cross-machine "Claude stack":

## 1. Claude Code CLI

Via the official installer: `curl -fsSL https://claude.ai/install.sh | bash`. Binary lands at `~/.local/bin/claude` (the `PATH` is already covered by topic `30-shell`).

**Login:** after installing, run `claude` and authenticate once per machine (OAuth with Anthropic — not transferable).

## 2. Syncthing (P2P file sync daemon)

Used to sync a curated subset of `~/.claude/` and `~/.claude-mem/` across N personal machines, **with no intermediate cloud**. The daemon runs as a user-level service and discovers peers via LAN + STUN/relay.

**Install:**

- **WSL / Linux**: `sudo apt-get install syncthing`; enables `systemctl --user enable --now syncthing.service` + `loginctl enable-linger $USER` (so it runs after logout).
- **macOS**: `brew install syncthing`; started via `brew services start syncthing`.

**Web UI:** http://localhost:8384 — first-use steps:
1. Set an admin password under *Settings → GUI* (even for localhost-only access).
2. Grab the device ID: `syncthing --device-id`.
3. Pair with other machines + accept shared folders.

**Pairing + folders flow** (what to sync, with which `.stignore`): documented in `~/dotfiles/claude/scripts/syncthing-setup.md` once the user's dotfiles are cloned (topic `95-dotfiles-personal`).

## Separation of concerns

This topic installs **tools** (CLI + daemon). The *content* (what to sync, how to configure the daemon, which `.stignore` to use) comes from the **personal dotfiles** via `95-dotfiles-personal`.

## Skip

If you don't use Claude Code or prefer to handle syncthing outside the bootstrap:

```bash
SKIP_TOPICS="80-claude-code" bash bootstrap.sh
```
