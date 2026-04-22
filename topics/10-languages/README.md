# 10-languages

Installs language runtimes:

- **Node LTS** via `fnm` (WSL: official installer; Mac: brew)
- **PHP (multi-version)** via `ondrej/php` PPA (WSL) or `brew php@X.Y` (Mac). Versions driven by `data/php-versions.conf` — the menu picks which to install and the last-selected becomes the CLI default. Switch later with `php-use <ver>`.
- **Composer** (WSL: official installer with checksum verification; Mac: brew). Bound to PHP default.
- **Current Python** (WSL: `python3` via apt; Mac: `python@3.13` via brew)

PHP extensions come from three lists in `data/`:

- `php-extensions-apt.txt` — baseline (bcmath, curl, gd, intl, mbstring, mysql, …) installed for every version
- `php-extensions-pecl.txt` — PECL extras (igbinary, imagick, mongodb, redis) built per-version
- `php-extensions-mssql.txt` — `sqlsrv` + `pdo_sqlsrv`, gated by `INCLUDE_MSSQL=1` (invoked from 60-laravel-stack)

Fragments in `templates/` configure `fnm env --use-on-cd` and Composer's `PATH` for both bash and zsh.

**To support a new PHP version** (e.g. 8.6 when released): add the line `8.6` to `data/php-versions.conf`. The installers, menu, nginx templates, and `php-use` all pick it up with no other code change.
