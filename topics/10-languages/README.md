# 10-languages

Installs language runtimes:

- **Node LTS** via `fnm` (WSL: official installer; Mac: brew)
- **PHP 8.4** + common extensions (WSL: `ondrej/php` PPA; Mac: `brew install php@8.4`)
- **Composer** (WSL: official installer with checksum verification; Mac: brew)
- **Current Python** (WSL: `python3` via apt; Mac: `python@3.13` via brew)

The fragments in `templates/` configure `fnm env --use-on-cd` and Composer's `PATH` for both bash and zsh.

**Customization:** change PHP version by editing `install.*.sh`. For multiple Node versions, use `fnm use <version>` per project.
