# Verify / Operational Audit — mesh-workstation install engine

> **Date:** 2026-06-03 · **Host probed:** mac (macOS, brew prefix `/Volumes/External/homebrew`) · **Scope:** all 131 catalog items / 12 topics · **Method:** per-item static read of `check()`/`verify()` + live read-only operational probe on the mac (workflow `wf_1d1d1643-e6f`, 133+84 agents), then an **adversarial verification pass** that independently re-checked all 62 critical/high findings — **53 confirmed, 9 refuted (phase-1 over-claims), 48 severities corrected.** The 2 criticals were also re-confirmed by hand.

Answers: *“o install só reportou tudo como keep, mas instalações antigas deram erro — não deveria rodar um check preciso? O que o verify de fato testa e cada item está operacional?”*

## TL;DR

**The intuition is correct, and 2 items are broken-but-kept on this mac right now — but after adversarial review the *actionable* list is 15 items, not 56.**

1. **The engine decides `keep` using ONLY `check()`** (`install-engine.sh:629-640`); the stronger `verify()` runs *only after an install*, so on the skip path it never runs. Weak `check()` ⇒ a broken item is kept and never caught.
2. **Structurally, `check()` is weaker than operational for 109/131 items.** Strength: `presence`=76, `filesystem`=14, `config-marker`=10, **`operational`=12**, `none/always-run`=19. And **only 8/131** items have `verify()` stronger than `check()` (the rest are `verify(){ check; }`).
3. **But most of those gaps are latent, not live.** The adversarial pass refuted 9 inflated highs and corrected 48 severities. What remains: **2 critical** (live divergence) + **13 high** (verified-real gaps that a realistic breakage would expose) = **15 worth fixing**; the other 116 are presence≈operational, wsl-distro, or idempotent (no skip path).
4. **Live operational status on this mac:** `yes`=83, `no`=3, `partial`=1, `n/a (wsl)`=44. The 2 `no` are the confirmed criticals.

| Final severity | Count | Meaning |
|---|---|---|
| **critical** | 2 | Live divergence on this mac: engine would KEEP but the item is NOT operational (both verified) |
| **high** | 13 | Verified-real false-keep gap: a realistic breakage would be silently kept (currently working) |
| **medium** | 59 | Presence≈operational in practice (low real risk) — many phase-1 highs corrected down to here |
| **low** | 36 | wsl distro packages, or refuted over-claims (gap theoretical, not live) |
| **ok** | 21 | Operational check, OR idempotent/deploy item that always re-runs (no skip gap) |

---

## 🔴 CRITICAL — broken-but-kept right now (2, both confirmed live)

### `remote-access/mosh/mosh-mac` — brew-formula  ·  ✅ confirmed by adversarial verifier

- **check() tests:** asserts the mosh formula is INSTALLED in the brew receipt DB; does NOT run mosh-server, the binary that actually serves incoming mosh sessions
- **broken because:** LIVE ON THIS MACHINE: protobuf was upgraded to 35.0.0 but mosh (1.4.0_38) was linked against libprotobuf.34.1.0.dylib, which no longer exists. `mosh-server --version` aborts with dyld 'Library not loaded: .../libprotobuf.34.1.0.dylib'. mosh is therefore non-operational as a remote-access server, yet `brew list --formula -- mosh` returns 0 (receipt + bin symlink present) so the engine prints 'already present, skipping' and never rebuilds it. Classic downstream-formula-not-rebuilt-after-dependency-major-bump.
- **engine now:** rc=0 (would KEEP) · **operational:** `no` · **divergence:** `True`
- **verifier note:** Confirmed exactly as claimed: engine KEEPS (rc=0) a non-operational remote-access server. Live downstream-not-rebuilt-after-protobuf-major-bump. critical + divergence + operational=no all hold.
- **fix:** THIS IS THE USER-REPORTED BUG, live. brew list keeps a mosh whose mosh-server cannot load its protobuf dylib. Fix on the machine: `brew reinstall mosh` (relinks against protobuf 35). Engine fix: add a _verify that runs `mosh-server --version` (or `mosh-server new` smoke), not just presence; a stronger verify would have caught this and forced a reinstall instead of KEEP. Driver-level: brew-formula items should optionally verify the spec's primary binary executes, since a dependency dylib bump silently breaks downstream formulae while keeping them 'listed'.

### `web/valet/valet` — custom  ·  ✅ confirmed by adversarial verifier

- **check() tests:** check() asserts three static filesystem/marker facts, all without invoking the valet CLI (deliberately, to avoid its internal sudo): (1) the resolved valet binary is executable (-x VALET_BIN, found via composer global bin-dir or ~/.composer / ~/.config/composer fallbacks); (2) directory ~/.config/valet exists; (3) ~/.config/valet/config.json exists AND grep matches "tld": "localhost". It never tests that nginx/dnsmasq/php-fpm daemons are loaded or serving.
- **broken because:** valet was installed once (binary present, ~/.config/valet + config.json with tld=localhost written, /Library/LaunchDaemons/homebrew.mxcl.{nginx,dnsmasq,php}.plist registered) but the daemons are NOT running — nginx not listening on :80, dnsmasq not answering .localhost on 127.0.0.1, php-fpm down, valet.sock dangling. Common real causes: daemons stopped/not auto-started after reboot, a parked path on an unmounted external volume, or nginx/php-fpm failing to start. check() asserts only the leftover filesystem markers, returns 0, and the engine prints "already present, skipping" while sites do not resolve/serve.
- **engine now:** rc=0 (would KEEP) · **operational:** `no` · **divergence:** `True`
- **verifier note:** confirmed and reproduced live: config-marker check passes while every valet daemon is down and sites return 000. divergence:true / operational:no accurate. Critical upheld.
- **fix:** DIVERGENCE on this live machine: check() returns rc=0 (engine KEEPs) but valet is not operational — nginx/dnsmasq/php-fpm daemons are down (no :80 listener, .localhost does not resolve, valet.sock dangling), so no parked site is being served. check() is config-marker only; verify() just re-calls check() so the strong post-install gate adds nothing. The script intentionally avoids the valet CLI in check() because the CLI shells out to sudo (and the menu scanner stubs sudo), which is a legitimate constraint — but it means check() can NEVER detect a dead serving stack. Recommended hardening: add a sudo-free operational probe to check() that asserts the stack is actually up, e.g. (a) a TCP connect test to 127.0.0.1:80 (nc/bash /dev/tcp) for nginx, and (b) a quick DNS probe of a *.localhost name against 127.0.0.1 with a short timeout for dnsmasq, and/or (c) confirm the valet.sock symlink target exists (php-fpm up). Any of these turns check() from config-marker into operational without needing sudo or the valet CLI. Because the item is non-idempotent and the binary/config persist across reboots, the current check() will indefinitely skip re-running `valet install`/service-start even when the machine reboots with daemons stopped. Note this is also a likely false-positive trigger on this box because parked paths live on /Volumes/External (an external volume) — if it isn't mounted, valet has nothing to serve yet check() still passes.

**Immediate machine repair (independent of any engine change):**

```bash
brew reinstall mosh                          # relink mosh-server vs protobuf 35 → fixes mosh-mac + mosh-path-mac
# valet (only if you still use it): bring the stack up and confirm it serves
valet install && valet restart && curl -I http://localhost/
```

---

## 🟠 HIGH — verified-real false-keep gaps (13)

Each independently confirmed (`✅`) as a real gap: the `check()` genuinely cannot catch a realistic broken state, even though the item works *now*. Note `mosh-path-mac` was **downgraded critical→high** by the verifier (reinstalling that item wouldn't fix the protobuf breakage — the real remedy is `brew reinstall mosh`).

**Gap classes & one-line fix:** clone/symlink `filesystem` (code-server, mosh-path, iterm2-font, tpm-clone, mkcert-wsl, nginx-sites) → require `[[ -e ]]` + a content sentinel, not bare existence; service `operational`-but-partial (rtk, moshi-hook-service ×2) → gate on the *functional* state install() guarantees (e.g. paired, not just daemon-up); `presence`/`config-marker` (mssql-driver, core-wsl, packages, tailscale-mtu-wsl) → add the functional probe install() implies.

| item | type | check | verify>chk | gap | op | verified |
|---|---|---|---|---|---|---|
| `ai/agent-tools/rtk` | custom | operational | · | ⚠ | yes | ✅ |
| `ai/moshi-hook/moshi-hook-mac-service` | custom | operational | · | ⚠ | yes | ✅ |
| `ai/moshi-hook/moshi-hook-wsl-service` | custom | operational | · | ⚠ | n/a | ✅ |
| `databases/mssql-driver/mssql-driver` | custom | presence | · | ⚠ | n/a | ✅ |
| `foundation/base/core-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `remote-access/code-server/code-server` | custom | filesystem | · | ⚠ | yes | ✅ |
| `remote-access/mosh/mosh-path-mac` | custom | filesystem | · | ⚠ | no | ✅ |
| `remote-access/tailscale/tailscale-mtu-wsl` | custom | config-marker | · | ⚠ | n/a | ✅ |
| `shell-terminal/fonts/iterm2-font-config` | custom | filesystem | · | · | yes | ✅ |
| `shell-terminal/tmux/tpm-clone` | custom | filesystem | ✔ | ⚠ | yes | ✅ |
| `web/nginx-php-fpm/mkcert` | custom | filesystem | · | ⚠ | n/a | ✅ |
| `web/nginx-php-fpm/nginx-sites` | custom | filesystem | · | ⚠ | n/a | ✅ |
| `web/nginx-php-fpm/packages` | custom | presence | · | ⚠ | n/a | ✅ |

## ⬇️ Refuted / over-claimed by the verifier (9 — phase-1 said high, real risk is low)

Kept for transparency: the gap *class* is genuine (presence-only check, verify bypassed) but there is **no live false-keep** on this machine, so severity was corrected down.

| item | high→ | why refuted |
|---|---|---|
| `ai/claude-code/claudebar` | low | check is genuinely weaker than verify-shape (config-marker vs doctor), but operational is 'yes' not 'partial': the statusline is a healthy 31KB self-contained script that executes and renders. None of the gap_scenario conditions (0-byte, missing binary, stale schema) hold here, so there is no live false_keep. Also npx_verify's `\|\| return 0` means doctor can't actually fail the item even post-install. Downgraded to low. |
| `languages/node/npm-global` | low | Finding's own engine_check_now already says rc!=0 (would REINSTALL) — i.e. NO false-keep on this machine; install()'s `mkdir -p` would correctly re-run. The false_keep_gap:true + severity:high framing is self-contradicting for this host (the stale-marker actually PROTECTS against the keep). Real divergence exists (old vs new marker) but it is benign/self-correcting, not a high-sev false-keep. REFUTED severity -> low. |
| `shell-terminal/nvim/neovim-mac` | low | Structural gap real (formula-name check only) but no broken-dep state here; nvim starts. Severity over-claimed high -> low. |
| `shell-terminal/tmux/tmux-mac` | low | Presence check genuinely can't catch an unlinked keg / broken dylib, but that state is not present (binary launches). No verify smoke-test exists, but this is latent defense-in-depth, not an active high bug. |
| `shell-terminal/zsh/zsh-history-substring-mac` | low | Same as syntax-highlighting: real structural presence-only gap but no active false-keep on this machine; share file sourceable. Over-claimed high -> low. |
| `shell-terminal/zsh/zsh-syntax-highlighting-mac` | low | Latent gap class is genuine (presence-only check, verify bypassed on skip), but severity over-claimed: no live false-keep here, share file sourceable, gap needs an externally-corrupted/unlinked keg the engine never creates. Plugin-share with no smoke-test = low, not high. |
| `syncthing/syncthing/syncthing-binary-mac` | low | Receipt-presence check indeed can't see a dangling bin link, but the link is healthy and binary runs; downstream service can launch. No active false-keep. Over-claimed high -> low. |
| `syncthing/syncthing/syncthing-service-mac` | low | over-claim: 'high' for a theoretical pgrep substring/port over-match. Service is operationally up; check is operational-in-intent and correct here. Realistic severity low (hardening nit: anchor pgrep / verify it is OUR job). |
| `web/valet/mkcert` | low | check_strength=presence and engine-would-KEEP are accurate, but the claimed false_keep_gap (dangling/unlinked symlink) does NOT exist on this machine: symlink is healthy and `mkcert -version` works. Presence == operational here; the gap is purely hypothetical, so 'high' over-claims a live defect that isn't present. Downgraded to low (theoretical weakness only). |

## 🟡 MEDIUM (59) · ⚪ LOW (36) · ✅ OK (21)

MEDIUM = presence≈operational (brew CLI tools, apt pkgs) — same structural gap as the mosh class but without the heavy native-dependency chain that breaks silently. LOW = wsl distro packages + the refuted over-claims. OK = idempotent/deploy items that **always re-run** (no skip path → no false-keep: the `*-fragments` deploys, `gitconfig-apply`, `personal/apply`, `drift-cleanup`, `generate-completions`, `migrate-legacy-nginx`, `atomic-skills`) + genuinely operational checks (`zsh-default-shell`, `zinit-drift-cleanup`).

| item | type | check | verify>chk | gap | op | verified |
|---|---|---|---|---|---|---|
| `ai/agent-tools/mdprobe` | npm-global | operational | · | ⚠ | yes | · |
| `ai/claude-code/bun` | custom | filesystem | · | ⚠ | yes | ✅ |
| `ai/claude-code/claude-code-cli` | custom | presence | · | ⚠ | yes | · |
| `ai/moshi-hook/moshi-hook-linux` | custom | presence | · | ⚠ | n/a | ✅ |
| `containers/docker/docker` | brew-formula | presence | · | ⚠ | yes | · |
| `containers/docker/docker-buildx` | apt | presence | · | ⚠ | n/a | · |
| `containers/docker/docker-compose` | brew-formula | presence | · | ⚠ | yes | · |
| `containers/docker/docker-compose-v2` | apt | presence | · | ⚠ | n/a | · |
| `containers/docker/docker-engine` | apt | presence | · | ⚠ | n/a | · |
| `containers/docker/docker-post-setup` | custom | config-marker | · | ⚠ | n/a | ✅ |
| `databases/mysql/mysql-mac` | custom | operational | · | ⚠ | yes | ✅ |
| `databases/mysql/mysql-wsl` | custom | presence | · | ⚠ | n/a | · |
| `databases/postgresql/postgresql` | custom | operational | · | ⚠ | yes | ✅ |
| `databases/redis/redis-mac` | custom | operational | · | ⚠ | yes | ✅ |
| `databases/redis/redis-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `foundation/base/core-mac` | custom | presence | · | ⚠ | yes | ✅ |
| `git/gpg-signing/gpg-signing` | custom | config-marker | · | ⚠ | n/a | · |
| `git/lazygit/lazygit-default-config` | custom | filesystem | · | ⚠ | yes | ✅ |
| `identity/identity/gh-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `identity/identity/gh-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `identity/identity/identity-setup` | custom | presence | · | ⚠ | yes | ✅ |
| `languages/php/php-stack-mac` | custom | presence | ✔ | ⚠ | yes | ✅ |
| `languages/php/php-stack-wsl` | custom | presence | ✔ | ⚠ | n/a | ✅ |
| `remote-access/ssh/openssh-server-wsl` | apt | presence | · | ⚠ | n/a | · |
| `remote-access/ssh/remote-login-mac` | custom | config-marker | · | ⚠ | yes | · |
| `remote-access/ssh/systemd-wsl` | custom | config-marker | · | ⚠ | n/a | ✅ |
| `remote-access/tailscale/tailscale-mac` | custom | presence | · | ⚠ | yes | ✅ |
| `remote-access/tailscale/tailscale-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/atuin-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/atuin-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/bat-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/btop-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/duf-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/dust-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/eza-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/fd-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/fzf-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/git-delta-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/git-delta-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/gping-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/lazygit-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/lazygit-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/ripgrep-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/rust-bins-wsl` | custom | filesystem | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/starship-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/starship-wsl` | custom | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/xh-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/zoxide-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/fonts/nerd-font-mac` | brew-cask | presence | · | ⚠ | yes | · |
| `shell-terminal/nvim/nvim-default-config` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/bat-catppuccin-theme` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/fzf-tab` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/powerlevel10k` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/shipped-configs` | custom | presence | · | ⚠ | yes | · |
| `shell-terminal/zsh/zinit` | custom | filesystem | · | ⚠ | yes | ✅ |
| `syncthing/syncthing/syncthing-binary-wsl` | apt | presence | · | ⚠ | n/a | · |
| `syncthing/syncthing/syncthing-service-wsl` | custom | operational | · | ⚠ | n/a | · |
| `web/mailpit/mailpit` | custom | presence | · | ⚠ | yes | ✅ |
| `web/valet/launchdaemon-hardening` | custom | config-marker | · | ⚠ | yes | ✅ |
| `ai/claude-code/claudebar` | npx | config-marker | ✔ | ⚠ | partial | ❌ |
| `ai/moshi-hook/moshi-hook-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `containers/docker/colima` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `identity/identity/wslu` | apt | presence | · | ⚠ | n/a | · |
| `languages/node/node-fnm` | custom | presence | · | ⚠ | yes | ✅ |
| `languages/node/npm-global` | custom | config-marker | · | ⚠ | yes | ❌ |
| `remote-access/mosh/mosh-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/bat-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/btop-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/eza-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/fd-find-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/forgit-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/fzf-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/procs-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/ripgrep-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/sd-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/tealdeer-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/tealdeer-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/zoxide-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/nvim/neovim-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/nvim/neovim-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/tmux/catppuccin-tmux-clone` | custom | config-marker | · | ⚠ | yes | · |
| `shell-terminal/tmux/tmux-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/tmux/tmux-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/zsh/atuin-login` | custom | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/shell-bootstrap` | custom | operational | · | ⚠ | yes | · |
| `shell-terminal/zsh/zsh-autosuggestions-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/zsh-autosuggestions-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/zsh/zsh-completions-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/zsh-history-substring-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/zsh/zsh-syntax-highlighting-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/zsh/zsh-syntax-highlighting-wsl` | apt | presence | · | ⚠ | n/a | · |
| `syncthing/syncthing/syncthing-binary-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `syncthing/syncthing/syncthing-service-mac` | custom | operational | · | ⚠ | yes | ❌ |
| `web/ngrok/ngrok` | custom | presence | · | ⚠ | yes | ✅ |
| `web/valet/mkcert` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `ai/agent-tools/atomic-skills` | npx | none-always-run | ✔ | · | yes | · |
| `ai/claude-code/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `git/config/gitconfig-apply` | custom | none-always-run | ✔ | · | yes | · |
| `git/config/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `languages/php/php-orphan-ini-cleanup-mac` | custom | none-always-run | · | · | yes | · |
| `personal/personal/apply` | custom | none-always-run | ✔ | · | yes | · |
| `remote-access/ssh/sshd-snippet` | deploy | none-always-run | · | · | yes | · |
| `remote-access/tailscale/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/cli-tools/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/fonts/windows-terminal-config` | custom | none-always-run | · | · | n/a | · |
| `shell-terminal/tmux/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/drift-cleanup` | custom | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/generate-zsh-completions` | custom | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/zinit-drift-cleanup` | custom | operational | · | · | yes | · |
| `shell-terminal/zsh/zsh-default-shell` | custom | operational | · | · | yes | · |
| `syncthing/syncthing/post-install-banner` | custom | none-always-run | · | · | n/a | · |
| `web/nginx-php-fpm/serve-config` | deploy | none-always-run | · | · | n/a | · |
| `web/ngrok/share-cli` | deploy | none-always-run | · | · | yes | · |
| `web/valet/migrate-legacy-nginx` | custom | none-always-run | ✔ | · | yes | · |
| `web/valet/serve-config` | deploy | none-always-run | · | · | yes | · |

---

## Recommended fixes (3 tiers)

### Tier 1 — engine/driver (closes whole classes)
1. **A `mesh doctor --deep` / engine `--verify` mode that runs every installed item's strongest probe regardless of the skip path** — the literal *“check preciso”*. Today `topics/*/verify.sh` are only `command -v` smoke tests and are **not wired into the engine**; this is the missing precise pass.
2. **`brew-formula` driver: optional `_verify` that runs the spec's primary binary** (per-item binary-name + smoke override; some tools lack `--version`). A dependency major-bump silently breaks every downstream formula while keeping it `listed` — the live mosh case, and the whole MEDIUM brew cluster shares the latent risk.
3. **Make `verify()` actually stronger than `check()`** (only 8/131 are today): where `verify(){ check; }`, upgrade `check()` to the operational probe so `verify()` inherits it.

### Tier 2 — per-item (the 13 verified highs)
clones/symlinks → `[[ -e ]]` + content sentinel (drop the dangling-symlink-passes branch); services → gate check() on the functional state (paired/listening), not just daemon-up; presence/marker items → add the probe install() implies.

### Tier 3 — machine now
`brew reinstall mosh` (fixes both mosh items); decide whether valet should be up and `valet restart` if so.

---

## Appendix — all 131 items (verified column: ✅ confirmed · ❌ refuted · · not reviewed)

| item | type | check | verify>chk | gap | op | verified |
|---|---|---|---|---|---|---|
| `remote-access/mosh/mosh-mac` | brew-formula | presence | · | ⚠ | no | ✅ |
| `web/valet/valet` | custom | config-marker | · | ⚠ | no | ✅ |
| `ai/agent-tools/rtk` | custom | operational | · | ⚠ | yes | ✅ |
| `ai/moshi-hook/moshi-hook-mac-service` | custom | operational | · | ⚠ | yes | ✅ |
| `ai/moshi-hook/moshi-hook-wsl-service` | custom | operational | · | ⚠ | n/a | ✅ |
| `databases/mssql-driver/mssql-driver` | custom | presence | · | ⚠ | n/a | ✅ |
| `foundation/base/core-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `remote-access/code-server/code-server` | custom | filesystem | · | ⚠ | yes | ✅ |
| `remote-access/mosh/mosh-path-mac` | custom | filesystem | · | ⚠ | no | ✅ |
| `remote-access/tailscale/tailscale-mtu-wsl` | custom | config-marker | · | ⚠ | n/a | ✅ |
| `shell-terminal/fonts/iterm2-font-config` | custom | filesystem | · | · | yes | ✅ |
| `shell-terminal/tmux/tpm-clone` | custom | filesystem | ✔ | ⚠ | yes | ✅ |
| `web/nginx-php-fpm/mkcert` | custom | filesystem | · | ⚠ | n/a | ✅ |
| `web/nginx-php-fpm/nginx-sites` | custom | filesystem | · | ⚠ | n/a | ✅ |
| `web/nginx-php-fpm/packages` | custom | presence | · | ⚠ | n/a | ✅ |
| `ai/agent-tools/mdprobe` | npm-global | operational | · | ⚠ | yes | · |
| `ai/claude-code/bun` | custom | filesystem | · | ⚠ | yes | ✅ |
| `ai/claude-code/claude-code-cli` | custom | presence | · | ⚠ | yes | · |
| `ai/moshi-hook/moshi-hook-linux` | custom | presence | · | ⚠ | n/a | ✅ |
| `containers/docker/docker` | brew-formula | presence | · | ⚠ | yes | · |
| `containers/docker/docker-buildx` | apt | presence | · | ⚠ | n/a | · |
| `containers/docker/docker-compose` | brew-formula | presence | · | ⚠ | yes | · |
| `containers/docker/docker-compose-v2` | apt | presence | · | ⚠ | n/a | · |
| `containers/docker/docker-engine` | apt | presence | · | ⚠ | n/a | · |
| `containers/docker/docker-post-setup` | custom | config-marker | · | ⚠ | n/a | ✅ |
| `databases/mysql/mysql-mac` | custom | operational | · | ⚠ | yes | ✅ |
| `databases/mysql/mysql-wsl` | custom | presence | · | ⚠ | n/a | · |
| `databases/postgresql/postgresql` | custom | operational | · | ⚠ | yes | ✅ |
| `databases/redis/redis-mac` | custom | operational | · | ⚠ | yes | ✅ |
| `databases/redis/redis-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `foundation/base/core-mac` | custom | presence | · | ⚠ | yes | ✅ |
| `git/gpg-signing/gpg-signing` | custom | config-marker | · | ⚠ | n/a | · |
| `git/lazygit/lazygit-default-config` | custom | filesystem | · | ⚠ | yes | ✅ |
| `identity/identity/gh-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `identity/identity/gh-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `identity/identity/identity-setup` | custom | presence | · | ⚠ | yes | ✅ |
| `languages/php/php-stack-mac` | custom | presence | ✔ | ⚠ | yes | ✅ |
| `languages/php/php-stack-wsl` | custom | presence | ✔ | ⚠ | n/a | ✅ |
| `remote-access/ssh/openssh-server-wsl` | apt | presence | · | ⚠ | n/a | · |
| `remote-access/ssh/remote-login-mac` | custom | config-marker | · | ⚠ | yes | · |
| `remote-access/ssh/systemd-wsl` | custom | config-marker | · | ⚠ | n/a | ✅ |
| `remote-access/tailscale/tailscale-mac` | custom | presence | · | ⚠ | yes | ✅ |
| `remote-access/tailscale/tailscale-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/atuin-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/atuin-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/bat-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/btop-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/duf-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/dust-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/eza-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/fd-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/fzf-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/git-delta-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/git-delta-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/gping-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/lazygit-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/lazygit-wsl` | custom | presence | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/ripgrep-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/rust-bins-wsl` | custom | filesystem | · | ⚠ | n/a | ✅ |
| `shell-terminal/cli-tools/starship-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/starship-wsl` | custom | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/xh-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/cli-tools/zoxide-mac` | brew-formula | presence | · | ⚠ | yes | · |
| `shell-terminal/fonts/nerd-font-mac` | brew-cask | presence | · | ⚠ | yes | · |
| `shell-terminal/nvim/nvim-default-config` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/bat-catppuccin-theme` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/fzf-tab` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/powerlevel10k` | custom | filesystem | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/shipped-configs` | custom | presence | · | ⚠ | yes | · |
| `shell-terminal/zsh/zinit` | custom | filesystem | · | ⚠ | yes | ✅ |
| `syncthing/syncthing/syncthing-binary-wsl` | apt | presence | · | ⚠ | n/a | · |
| `syncthing/syncthing/syncthing-service-wsl` | custom | operational | · | ⚠ | n/a | · |
| `web/mailpit/mailpit` | custom | presence | · | ⚠ | yes | ✅ |
| `web/valet/launchdaemon-hardening` | custom | config-marker | · | ⚠ | yes | ✅ |
| `ai/claude-code/claudebar` | npx | config-marker | ✔ | ⚠ | partial | ❌ |
| `ai/moshi-hook/moshi-hook-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `containers/docker/colima` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `identity/identity/wslu` | apt | presence | · | ⚠ | n/a | · |
| `languages/node/node-fnm` | custom | presence | · | ⚠ | yes | ✅ |
| `languages/node/npm-global` | custom | config-marker | · | ⚠ | yes | ❌ |
| `remote-access/mosh/mosh-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/bat-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/btop-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/eza-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/fd-find-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/forgit-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/fzf-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/procs-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/ripgrep-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/sd-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/tealdeer-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/cli-tools/tealdeer-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/cli-tools/zoxide-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/nvim/neovim-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/nvim/neovim-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/tmux/catppuccin-tmux-clone` | custom | config-marker | · | ⚠ | yes | · |
| `shell-terminal/tmux/tmux-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/tmux/tmux-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/zsh/atuin-login` | custom | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/shell-bootstrap` | custom | operational | · | ⚠ | yes | · |
| `shell-terminal/zsh/zsh-autosuggestions-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/zsh-autosuggestions-wsl` | apt | presence | · | ⚠ | n/a | · |
| `shell-terminal/zsh/zsh-completions-mac` | brew-formula | presence | · | ⚠ | yes | ✅ |
| `shell-terminal/zsh/zsh-history-substring-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/zsh/zsh-syntax-highlighting-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `shell-terminal/zsh/zsh-syntax-highlighting-wsl` | apt | presence | · | ⚠ | n/a | · |
| `syncthing/syncthing/syncthing-binary-mac` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `syncthing/syncthing/syncthing-service-mac` | custom | operational | · | ⚠ | yes | ❌ |
| `web/ngrok/ngrok` | custom | presence | · | ⚠ | yes | ✅ |
| `web/valet/mkcert` | brew-formula | presence | · | ⚠ | yes | ❌ |
| `ai/agent-tools/atomic-skills` | npx | none-always-run | ✔ | · | yes | · |
| `ai/claude-code/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `git/config/gitconfig-apply` | custom | none-always-run | ✔ | · | yes | · |
| `git/config/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `languages/php/php-orphan-ini-cleanup-mac` | custom | none-always-run | · | · | yes | · |
| `personal/personal/apply` | custom | none-always-run | ✔ | · | yes | · |
| `remote-access/ssh/sshd-snippet` | deploy | none-always-run | · | · | yes | · |
| `remote-access/tailscale/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/cli-tools/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/fonts/windows-terminal-config` | custom | none-always-run | · | · | n/a | · |
| `shell-terminal/tmux/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/drift-cleanup` | custom | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/generate-zsh-completions` | custom | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/shell-fragments` | deploy | none-always-run | · | · | yes | · |
| `shell-terminal/zsh/zinit-drift-cleanup` | custom | operational | · | · | yes | · |
| `shell-terminal/zsh/zsh-default-shell` | custom | operational | · | · | yes | · |
| `syncthing/syncthing/post-install-banner` | custom | none-always-run | · | · | n/a | · |
| `web/nginx-php-fpm/serve-config` | deploy | none-always-run | · | · | n/a | · |
| `web/ngrok/share-cli` | deploy | none-always-run | · | · | yes | · |
| `web/valet/migrate-legacy-nginx` | custom | none-always-run | ✔ | · | yes | · |
| `web/valet/serve-config` | deploy | none-always-run | · | · | yes | · |
