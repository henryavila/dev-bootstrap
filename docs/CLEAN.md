# `mesh clean` — disk reclaim

OS-aware disk reclaim for any machine in the mesh (mac · WSL · native Linux).
Purges **regenerable dev caches**, and on WSL hands off the **VHDX compaction**
that actually returns the freed space to the Windows host.

## TL;DR

```sh
mesh clean                         # dry-run: what can be reclaimed (deletes nothing)
mesh clean --apply                 # purge Tier-1 caches (regenerable, no re-download)
mesh clean --apply --deep          # also purge Tier-2 (browser + ML model caches)
mesh clean --apply --deep --compact   # WSL: reclaim, then shrink the ext4.vhdx
```

`mesh clean` with no flags is **always safe** — it only measures.

## Why two phases on WSL

A WSL2 distro lives in an `ext4.vhdx` on the Windows host. That file **grows but
never auto-shrinks**: deleting files inside WSL frees space *inside* the distro
but the `.vhdx` on `C:` stays just as large. So reclaim is two phases:

1. **Phase A — `mesh clean --apply`** (inside WSL): purge caches → shrinks usage.
2. **Phase B — `mesh clean --compact`** (handoff to Windows): compact the VHDX so
   the freed space returns to `C:`. This *must* run from Windows — you cannot shut
   the distro down from inside it — so `--compact` prints the exact command:

   ```powershell
   wsl --shutdown
   wsl --manage <distro> --set-sparse true
   ```

   `--set-sparse true` compacts now **and** makes the disk auto-shrink from then
   on. No admin and no Hyper-V required on WSL 2.x. The bundled
   [`windows/wsl-compact.ps1`](../windows/wsl-compact.ps1) does the same with a
   before/after size report (and an optional `-DiskPart` one-shot fallback).

## Tiers

| Tier | When | Examples | Cost of deleting |
|------|------|----------|------------------|
| **1** (default `--apply`) | regenerable, cheap to rebuild | npm · pip · uv · composer · apt archives · systemd journal · JetBrains caches · node-gyp · Homebrew (mac) | none — rebuilt transparently |
| **2** (`--deep`) | heavy, re-downloaded on next use | Playwright / Puppeteer browsers · PyTorch · HuggingFace model caches | re-download time/bandwidth |

`mesh clean` **never** touches source code, virtualenvs, secrets, or
`~/.local/share` data.

## Adding a cleaner

Cleaners are modular — one file per tool under
[`scripts/lib/cleaners/`](../scripts/lib/cleaners/), mirroring
`scripts/lib/installers/`. To add one, drop in `<name>.sh` defining:

```sh
cleaner_<name>_tier()    { echo 1; }                 # 1 or 2
cleaner_<name>_desc()    { echo "human description"; }
cleaner_<name>_applies() { _clean_paths_applies "$HOME/.cache/<name>"; }  # OS/tool guard
cleaner_<name>_measure() { _clean_bytes_of      "$HOME/.cache/<name>"; }  # read-only
cleaner_<name>_clean()   { _clean_paths_clean   "$HOME/.cache/<name>"; }  # deletes
```

Path-based cleaners delegate to the `_clean_paths_*` helpers in
[`_lib.sh`](../scripts/lib/cleaners/_lib.sh); OS/command cleaners (apt, journal,
brew) implement `measure`/`clean` themselves and gate on `$CLEAN_OS` + tool
presence. `mesh clean` discovers every module automatically — no central list to
edit. Add Mac/Linux support to an existing cleaner by relaxing its
`*_applies` guard.

## Flags

| Flag | Effect |
|------|--------|
| _(none)_ | dry-run report; deletes nothing |
| `--apply` | purge Tier-1 caches |
| `--deep` | also purge Tier-2 caches |
| `--compact` | WSL VHDX compaction handoff (no-op off-WSL) |
| `--yes` / `-y` | skip the `--apply` confirmation (automation) |
