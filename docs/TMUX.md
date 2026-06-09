# tmux — keybindings & usage

The mesh tmux config sets the **prefix to `Ctrl-a`** (screen-style), **not** the upstream
default `Ctrl-b`. If you press `Ctrl-b` nothing happens — that is the #1 reason the
shortcuts "don't work". This page is the cheat-sheet that the topic was missing.

Config source: [`topics/shell-terminal/templates/tmux/tmux.conf`](../topics/shell-terminal/templates/tmux/tmux.conf)
· deployed to `~/.tmux.conf` · session-management aliases (`tl`/`ta`/`tn`/`tm`) live in [`ALIASES.md`](ALIASES.md).

## How tmux keybindings work (read this first)

- **Prefix = `Ctrl-a`.** Press `Ctrl-a`, **release**, *then* the command key. It is a
  **two-step chord**, not a single held combo. Notation below: `‹p›` means "press the
  prefix, then…". So `‹p› |` = `Ctrl-a`, release, `|`.
- To type a **literal `Ctrl-a`** (e.g. emacs beginning-of-line) or to drive an **inner
  tmux when nested**: press `Ctrl-a` then `Ctrl-a` again (`send-prefix`).
- Legend: **★** = customized by mesh · *(default)* = built-in tmux binding kept active.

## Panes

| Keys | Action | |
|---|---|---|
| `‹p› \|` | Split **side-by-side** (horizontal), keeps cwd | ★ `\|` needs `AltGr` on ABNT2 / symbol layer on iOS |
| `‹p› -` | Split **stacked** (vertical), keeps cwd | ★ |
| `‹p› h` `j` `k` `l` | Move focus left/down/up/right (vi) | ★ |
| `‹p› ←` `↓` `↑` `→` | Move focus (arrows, repeatable) | *(default)* |
| `‹p› o` | Cycle to next pane | *(default)* |
| `‹p› ;` | Jump to last (previous) pane | *(default)* |
| `‹p› Ctrl-←/↓/↑/→` | **Resize** by 1 cell (hold to repeat) | *(default)* |
| `‹p› Alt-←/↓/↑/→` | **Resize** by 5 cells | *(default)* · macOS needs "Option as Meta" |
| `‹p› z` | **Zoom** pane to full window (toggle) | *(default)* |
| `‹p› x` | Close pane (asks to confirm) | *(default)* |
| `‹p› {` / `‹p› }` | Swap pane with previous / next | *(default)* |
| `‹p› >` | **Pane menu** (split/swap/zoom via keyboard or mouse) | *(default)* |
| `‹p› q` | Flash pane numbers (press the number to jump) | *(default)* |

> **Resize exists.** It is just the tmux *default* (`‹p›` then `Ctrl`/`Alt`+arrow), so it
> is easy to miss — the mesh config adds `|`/`-`/`hjkl` but does not add letter-based
> resize. On touch (Moshi) you can also **drag a pane border** since mouse is on.

## Windows

| Keys | Action | |
|---|---|---|
| `‹p› c` | New window | *(default)* |
| `‹p› n` / `‹p› p` | Next / previous window | *(default)* |
| `‹p› 1`…`9` | Jump to window by number (numbering starts at **1**) | *(default)* |
| `‹p› ,` | Rename current window | *(default)* |
| `‹p› &` | Kill window (asks to confirm) | *(default)* |
| `‹p› w` | Window/session chooser (interactive list) | *(default)* |
| `‹p› <` | **Window menu** (swap/rename/kill/new via menu) | *(default)* |

## Scroll & copy (copy-mode, vi keys)

| Keys | Action | |
|---|---|---|
| `‹p› [` | Enter **copy-mode** (then scroll with arrows / `PageUp` / `Ctrl-u`/`Ctrl-d`) | *(default)* |
| `‹p› PageUp` | Enter copy-mode already scrolled up one page | *(default)* |
| in copy-mode: `v` | Start selection | ★ |
| in copy-mode: `V` | Select whole line | ★ |
| in copy-mode: `Ctrl-v` | Toggle rectangular (block) selection | ★ |
| in copy-mode: `y` | Copy selection and exit | ★ ⚠️ lands in the **tmux buffer only** — not yet the OS clipboard (see Caveats) |
| in copy-mode: `q` / `Esc` | Leave copy-mode | *(default)* |
| `‹p› ]` | Paste the tmux buffer | *(default)* |

Copy-mode is what gives you scrollback over **mosh** (mosh itself has none) — always run
long-lived/mobile sessions inside tmux so `‹p› [` works.

## Sessions (from the shell, not in-tmux)

`‹p› d` detaches (leaves the session running). To list/attach/create from a normal shell,
use the aliases — full table in [`ALIASES.md`](ALIASES.md#40-tmux--session-shortcuts):

| Alias | Does |
|---|---|
| `tl` | list sessions (`tmux ls`) |
| `ta <name>` | attach / switch to a session by name (no nested clients) |
| `tn <name>` | new session |
| `tm` | go to the canonical `main` session |

## Mouse

Mouse is **on**: click to focus a pane, **drag a border to resize**, scroll with the
wheel / a finger (Moshi). Because tmux owns the mouse, native click-drag text selection is
intercepted — **hold `Shift` while selecting** to bypass tmux and select for the OS
clipboard (exact modifier varies per emulator; on iOS use the client's selection gesture).

## Status bar & misc

| Keys | Action |
|---|---|
| `‹p› r` | Reload `~/.tmux.conf` ★ |
| `‹p› d` | Detach from session *(default)* |
| `‹p› t` | Big clock *(default)* |
| `‹p› ?` | List **all** key bindings *(default)* |

Status bar is at the **top** (`status-position top`) so the on-screen keyboard on phones
doesn't cover it. Theme is Catppuccin Mocha (via TPM/catppuccin), status-right shows the
pane cwd + `user@host`.

## Per-client notes

- **Windows Terminal (WSL — ultron / crc):** prefix `Ctrl-a` passes through fine. If a
  `‹p› Ctrl-arrow`/`Alt-arrow` resize seems dead, check Windows Terminal isn't binding
  that combo for its own action (Settings → Actions).
- **macOS terminal (iTerm2):** to use `‹p› Alt-arrow` (resize by 5) the terminal must send
  Option as Meta — iTerm2: *Profiles → Keys → Left Option key → Esc+*. Letter bindings
  (`hjkl`) and everything else work without it.
- **Moshi (iPhone / mosh):** `|`, `-` and arrows live in the symbol/secondary layer, so
  prefer **`hjkl`** for navigation, the **pane menu `‹p› >`**, and **touch-drag** to
  resize. `Ctrl` is on the accessory key row (tap `Ctrl`, then the key). Nested sessions
  need the double prefix (below). Always run inside tmux for scrollback over mosh.

## Caveats / known gaps

- **Nested tmux (cockpit → remote: `ultron → ssh mac → tmux`):** both layers use `Ctrl-a`,
  so every command for the **inner** tmux is `Ctrl-a Ctrl-a ‹key›` (e.g. inner split =
  `Ctrl-a Ctrl-a |`). A single `Ctrl-a` drives the **outer** tmux. A distinct inner prefix
  is under consideration.
- **`y` does not reach the system clipboard yet** — it only fills the internal tmux buffer.
  Cross-device clipboard (OSC52 / `set-clipboard`) is not configured yet.

These are tracked in the terminal/tmux audit; fixes are pending.
