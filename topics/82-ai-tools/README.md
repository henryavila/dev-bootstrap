# 82-ai-tools (opt-in)

Installs optional AI workflow tools via the engine `items.yaml` manifest.

The topic needs `MESH_IDENTITY_REPO` because the package manifest and installer live
in the identity repo, but it does not run `$MESH_IDENTITY_DIR/install.sh`.

```bash
INCLUDE_AI_TOOLS=1 MESH_IDENTITY_REPO=git@github.com:youruser/mesh-identity.git bash setup.sh
```

AI tool packages (mdprobe, atomic-skills, rtk) are declared in `items.yaml`
and installed via the engine's driver system.

The default manifest currently exposes:

| Tool | Essence |
|------|---------|
| `mdprobe` | Markdown review UI with live reload, persistent annotations, section approval, and an MCP loop so agents can read and resolve human feedback. |
| `atomic-skills` | Focused, reusable agent skills/prompts rendered for detected AI IDEs such as Claude Code, Codex, Gemini, Cursor, and related tools. |
| `rtk` | Rust CLI proxy that compresses noisy shell output before it reaches an AI agent context, covering git, tests, linters, logs, containers, cloud CLIs, and file/search commands. |

If the identity repo has not been cloned yet, topic 82 clones it first.
Installed packages are skipped unless the run sets `MESH_AI_PACKAGES_UPDATE=1`.
Non-interactive runs install the full manifest; only missing items are installed.
