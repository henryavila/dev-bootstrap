# docs

- [`INSTALL-WINDOWS-WSL.md`](INSTALL-WINDOWS-WSL.md) — **fresh Windows → WSL2 Ubuntu → mesh setup** (host script, Phase 0, lean bootstrap, fonts, systemd, troubleshooting).
- [`SPEC.md`](SPEC.md) — technical specification (architecture, topics, acceptance criteria, roadmap). Guest/server mode: SPEC §4 `--no-mesh` / `MESH_NO_MESH`.
- [`SERVICES.md`](SERVICES.md) — `mesh services` control plane (systemd on WSL · brew/launchd on mac).
- [`CLEAN.md`](CLEAN.md) — disk reclaim + WSL VHDX compaction handoff.
- [`TMUX.md`](TMUX.md) — tmux keybindings cheat-sheet. **Prefix is `Ctrl-a`** (not `Ctrl-b`); splits, panes, resize, windows, copy-mode, per-client notes.
- [`ALIASES.md`](ALIASES.md) — shell aliases every dev receives (incl. tmux session helpers `tl`/`ta`/`tn`/`tm`).

Topic-specific READMEs live under `topics/<topic>/README.md`.
