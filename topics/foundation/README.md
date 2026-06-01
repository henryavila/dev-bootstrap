# 00-core

Installs the minimum tools every later topic assumes and that the runner itself depends on.

**WSL packages:** `git curl wget ca-certificates gnupg build-essential jq unzip gettext-base`
**macOS packages:** `git curl wget gnupg jq unzip gettext` (+ installs Homebrew when missing)

**No templates** — this topic cannot depend on `lib/deploy.sh`, because `deploy.sh` uses `envsubst`, which this topic installs. Any corresponding shell configuration lives in `30-shell`.

**Customization:** edit `install.$OS.sh` to add minimum packages used everywhere.
