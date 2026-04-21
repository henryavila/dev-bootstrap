# 90-editor (opt-in)

Enabled via `INCLUDE_EDITOR=1 bash bootstrap.sh` (or by checking it in the interactive menu).

**Installs two CLI wrappers** that open `.md` files in **Typora** (GUI) from the terminal:

| Command | Blocks? | Use case |
|---|---|---|
| `typora foo.md` | ❌ no | Quick open — returns prompt immediately. Default choice. |
| `typora-wait foo.md` | ✅ yes | Blocks until window closes — useful as `$EDITOR` or in scripts that need to wait for edits. |

Both live in `~/.local/bin/` (covered by topic `30-shell` PATH).

## Problem it solves

You're in the terminal and want to **read or edit** a `.md` rendered in Typora's GUI without opening File Explorer / Finder / etc. manually. On WSL, the extra pain: Typora lives on the Windows side, so paths need conversion (`wslpath -w`) and the `.exe` is invoked via interop. These wrappers hide all of that.

```bash
typora notes.md                   # quick open, returns to prompt
typora new-draft.md               # opens "create new file?" dialog if missing
typora doc1.md doc2.md            # multiple files

typora-wait notes.md              # blocks until Typora window closes
EDITOR=typora-wait git commit     # use as git's editor
```

## Platforms

- **macOS**:
  - For **existing files**: `open -a Typora` (LaunchServices — reuses the running Typora instance when present; opens fresh otherwise).
  - For **missing files**: `/Applications/Typora.app/Contents/MacOS/Typora <path>` directly. This is the only path that triggers Typora's "create this file?" dialog — the official doc ([support.typora.io/Use-Typora-From-Shell-or-cmd](https://support.typora.io/Use-Typora-From-Shell-or-cmd/)) explicitly notes that `open -a` doesn't offer creation.
  - `typora-wait` additionally passes `-W` to `open` so the shell blocks.
  - Prerequisite check: `osascript -e 'id of app "Typora"'` gives a clear error when the app isn't installed.
- **WSL**: detects via `/proc/version`, searches for `Typora.exe` in:
  - `C:\Program Files\Typora\`
  - `C:\Program Files (x86)\Typora\`
  - `%LOCALAPPDATA%\Programs\Typora\`

  Each file argument is converted with `wslpath -w` before being passed. `typora-wait` passes `--wait` to Typora.exe; `typora` omits it and backgrounds via `disown`.
- **Native Linux**: falls back to system-installed `/usr/bin/typora` / `/usr/local/bin/typora` (AppImage or `.deb` installed manually). The wrapper uses an absolute path to the system binary to avoid re-invoking itself.
- **Windows native (CMD/PowerShell)**: out of scope for dev-bootstrap. Follow the official doc — add `typora.exe` to the Windows PATH once, then `typora file.md` works from cmd/pwsh directly.

## Prerequisite

Typora must be **installed on the host platform** — the bootstrap does NOT install Typora itself (it's a paid license). Manual setup:

- **Mac**: `brew install --cask typora` (or download from [typora.io](https://typora.io))
- **Windows (used from WSL)**: installer from [typora.io](https://typora.io)
- **Native Linux**: AppImage or `.deb` from the official site

## Note on `$EDITOR`

`typora-wait` used to be the default `$EDITOR`. That role belongs to nvim now (see `shell/bashrc.local` / `shell/zshrc.local` in your personal dotfiles). Both wrappers remain available for ad-hoc use.
