# 70-remote-access (opt-in)

Enabled via `INCLUDE_REMOTE=1 bash bootstrap.sh`.

**Installs:** `openssh-server` + `mosh` + `tailscale`. Activates sshd, enables systemd on WSL (`/etc/wsl.conf`).

**Legacy NOPASSWD removal** (since v2026-04-22): earlier versions of this topic created `/etc/sudoers.d/10-${USER}-nopasswd` with `NOPASSWD: ALL` as a convenience during bootstrap. That was unnecessary permanent attack surface — the main `bootstrap.sh` now runs `sudo -v` at startup (cache warmup, ~5–15 min), covering the whole bootstrap duration with a single prompt. Forks that already had the file: this topic removes it automatically on the next run.

**Applies (WSL):** systemd drop-in to fix the tailscale0 MTU — see the "Tailscale MTU gotcha" section below.

**Deploys:**
- `/etc/ssh/sshd_config.d/99-${USER}.conf` with hardening (PasswordAuth off, PubkeyAuth on, AllowUsers restricted).
  `envsubst` expands `${USER}`. `lib/deploy.sh` detects the path sits outside `$HOME` and elevates via sudo automatically.
- **(WSL)** `/etc/systemd/system/tailscaled.service.d/mtu.conf` — drop-in that runs `ip link set tailscale0 mtu 1200` at every `tailscaled` start. Idempotent: only rewrites if content differs.

**Post-install:**
1. Exit and run `wsl --shutdown` (Windows) to apply systemd.
2. `sudo tailscale up` to authenticate.
3. Copy your public key into the user's `~/.ssh/authorized_keys`.

---

## Tailscale MTU gotcha (post-quantum SSH KEX)

### Symptom

`ssh <host>` over Tailscale hangs forever at `SSH2_MSG_KEX_ECDH_REPLY`, even with `tailscale ping` returning in <10 ms. Only affects connections with OpenSSH 9.6+ (which negotiates post-quantum KEX by default).

### Cause

Bug pipeline:

1. Tailscale uses WireGuard with a default MTU of 1280.
2. OpenSSH 9.6+ negotiates `sntrup761x25519-sha512@openssh.com` → KEX messages of ~3–4 KB.
3. Inside an MTU-1280 tunnel, without reliable Path MTU Discovery, large fragments are silently dropped.
4. The client waits on a `KEX_ECDH_REPLY` that never arrives → timeout after ~2 min.

Reducing MTU **client-side via `~/.ssh/config` (`KexAlgorithms curve25519`) alone does NOT fix it** — host keys, banners, and other handshake messages can also exceed MTU.

### Fix applied (WSL — automated)

This topic writes `/etc/systemd/system/tailscaled.service.d/mtu.conf`:

```ini
[Service]
ExecStartPost=/usr/sbin/ip link set tailscale0 mtu 1200
```

The drop-in runs **every time** `tailscaled` starts, so it survives reboots and Tailscale reinstalls. Theoretical throughput cost inside the tunnel: ~6%. Imperceptible for SSH/mosh usage.

Idempotency: `install.wsl.sh` reads the file before writing — if content matches exactly, it doesn't touch it. If it differs, it rewrites + `daemon-reload` + (if `tailscaled` is active) `restart tailscaled`.

### Fix on macOS (manual)

Tailscale on Mac ships as a `.app` (via `brew install --cask tailscale`). The daemon is managed by the app itself; no equivalent systemd drop-in. The interface is `utun<N>` with variable N.

The topic installs `scripts/mac-tailscale-mtu-fix.sh`, which:
1. Detects the current Tailscale interface (via `tailscale ip -4` + `ifconfig` scan of `utun*`).
2. Runs `ifconfig <utun> mtu 1200`.

**On-demand usage** (when SSH hangs via Tailscale):

```bash
sudo bash ~/dev-bootstrap/topics/70-remote-access/scripts/mac-tailscale-mtu-fix.sh
```

Does not persist reboots — re-run after boot or re-login. For persistent automation, add a custom LaunchDaemon that runs the script at startup (TODO — not automated to avoid being invasive with the user-managed app).

### Verification

- **WSL**: `ip link show tailscale0` should report `mtu 1200`. The topic's `verify.sh` checks the drop-in + the applied MTU if the interface is up.
- **Mac**: `ifconfig utun<N> | grep mtu` where `<N>` is the current Tailscale interface.

### References

Detailed diagnostics + known variations in `ssh-tailscale-mtu-gotcha.md` (memory file in the personal dotfiles).

---

## Skip

If you don't use Tailscale or mosh:

```bash
# don't set INCLUDE_REMOTE=1 (default skip)
bash bootstrap.sh
```
