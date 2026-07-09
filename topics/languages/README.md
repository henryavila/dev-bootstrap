# 10-languages

Installs language runtimes:

- **Node LTS** via `fnm` (WSL: official installer; Mac: brew)
- **PHP (multi-version)** via `ondrej/php` PPA (WSL) or `brew php@X.Y` (Mac). Versions driven by `data/php-versions.conf` — the menu picks which to install and the last-selected becomes the CLI default. Switch later with `php-use <ver>`.
- **Composer** (WSL: official installer with checksum verification; Mac: brew). Bound to PHP default.
- **Current Python** (WSL: `python3` via apt; Mac: `python@3.13` via brew)

PHP extensions come from three lists in `data/`:

- `php-extensions-apt.txt` — baseline (bcmath, curl, gd, intl, mbstring, mysql, …) installed for every version
- `php-extensions-pecl.txt` — mandatory PECL baseline (igbinary, imagick, mongodb, pcov, redis) built per-version
- `php-extensions-mssql.txt` — `sqlsrv` + `pdo_sqlsrv`, gated by `INCLUDE_MSSQL=1` (invoked from 60-web-stack)

## PECL policy

The baseline entries in `data/php-extensions-pecl.txt` are mandatory for every
version declared by `data/php-versions.conf` or `PHP_VERSIONS`. `install()` and
`repair()` must attempt each baseline extension for each declared PHP version.
If a build fails, the expected `.so` is missing, or an active extension `.ini`
points at a missing `.so`, the PHP stack is broken and must not be reported as
green.

`check()` remains a cheap presence probe for Composer, Python, and declared PHP
packages/formulae. `verify()` is the health authority: it must prove each PHP
version starts without `PHP Startup` warnings and that baseline PECL extensions
load cleanly. A future optional extension policy must use an explicit quarantine
decision; silently skipping a baseline PECL entry is not a valid success path.

Fragments in `templates/` configure `fnm env --use-on-cd` and Composer's `PATH` for both bash and zsh.

**To support a new PHP version** (e.g. 8.6 when released): add the line `8.6` to `data/php-versions.conf`. The installers, menu, nginx templates, and `php-use` all pick it up with no other code change.
