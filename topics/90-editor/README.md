# 90-editor (opt-in)

Enabled via `INCLUDE_EDITOR=1 bash bootstrap.sh` (or by checking it in the interactive menu).

**Installs:** `~/.local/bin/typora-wait` — CLI helper that opens `.md` files in **Typora** (GUI) from the terminal and blocks until the window is closed.

## Problem it solves

You're in the terminal and want to **read** a `.md` rendered in a comfortable GUI (Typora) without opening File Explorer / Finder / etc. manually. On WSL, the extra pain: Typora lives on the Windows side, so you need to convert paths (`wslpath -w`) and invoke the `.exe` via interop.

```bash
typora-wait notes.md              # opens in Typora, blocks until closed
typora-wait doc.md report.md      # multiple files
```

## Platforms

- **macOS**: `open -W -a Typora` via LaunchServices — resolves the app by name in any registered location (`/Applications`, `~/Applications`, or wherever Spotlight has indexed it). `-W` blocks until Typora exits. A prior check with `osascript -e 'id of app "Typora"'` gives a clear error when the app isn't installed.
- **WSL**: detects via `/proc/version`, searches for `Typora.exe` in `C:\Program Files\`, `Program Files (x86)\`, and `%LOCALAPPDATA%\Programs\Typora\`. Each file argument is converted with `wslpath -w` before being passed.
- **Native Linux**: falls back to `command -v typora` (AppImage or `.deb` installed manually).

## Prerequisite

Typora must be **installed on the host platform** — the bootstrap does NOT install Typora itself (it's a paid license). Manual setup:

- **Mac**: `brew install --cask typora`
- **Windows (for use via WSL)**: installer from [typora.io](https://typora.io)
- **Native Linux**: AppImage or `.deb` from the official site

## Note on `$EDITOR`

This wrapper is **no longer** used as `$EDITOR` — nvim owns that role now (see `shell/bashrc.local` / `shell/zshrc.local` in your personal dotfiles). `typora-wait` is positioned as an "on-demand `.md` opener" instead.
