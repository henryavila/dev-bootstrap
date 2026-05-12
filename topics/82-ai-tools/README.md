# 82-ai-tools (opt-in)

Installs optional AI workflow tools from the selected dotfiles manifest without
applying personal dotfiles.

The topic needs `DOTFILES_REPO` because the package manifest and installer live
in the dotfiles repo, but it does not run `$DOTFILES_DIR/install.sh`.

```bash
INCLUDE_AI_TOOLS=1 DOTFILES_REPO=git@github.com:youruser/dotfiles.git bash bootstrap.sh
```

In interactive mode, selecting `82-ai-tools` opens a package selector before the
final bootstrap confirmation when the dotfiles manifest is available locally.
That selection is passed to the dotfiles AI installer via
`DOTFILES_AI_PACKAGE_SELECTION`.

The default manifest currently exposes:

| Tool | Essence |
|------|---------|
| `mdprobe` | Markdown review UI with live reload, persistent annotations, section approval, and an MCP loop so agents can read and resolve human feedback. |
| `atomic-skills` | Focused, reusable agent skills/prompts rendered for detected AI IDEs such as Claude Code, Codex, Gemini, Cursor, and related tools. |
| `rtk` | Rust CLI proxy that compresses noisy shell output before it reaches an AI agent context, covering git, tests, linters, logs, containers, cloud CLIs, and file/search commands. |

If the dotfiles repo has not been cloned yet, topic 82 clones it first and then
falls back to the dotfiles installer's selector during the topic run. Installed
packages are skipped unless the run sets `DOTFILES_AI_PACKAGES_UPDATE=1`.
Non-interactive runs select the full manifest and only install what is missing.
