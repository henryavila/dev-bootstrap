# databases (opt-in)

Local database servers and drivers for development. Split out of the former
`60-web-stack` topic in the Manifest v2 reorganization (F9.6).

Selected in the interactive menu (the `databases` topic).

## Bundles

| Bundle | Platforms | What you get |
|---|---|---|
| `mysql` | mac + wsl | MySQL 8 — brew `mysql@8.0` (+ Oracle DMG fallback) on mac, apt `mysql-server-8.0` on WSL |
| `redis` | mac + wsl | Redis — brew on mac, apt `redis-server` on WSL |
| `postgresql` | mac + wsl | PostgreSQL server; major version chosen via the bundle's `POSTGRES_VERSION` option (default 17) |
| `mssql-driver` | wsl | MS SQL Server ODBC driver (msodbcsql18 + mssql-tools18) + PHP `sqlsrv`/`pdo_sqlsrv` PECL extensions when PHP is present |

## Relationship to `web`

The `web` topic's `valet` (mac) and `nginx-php-fpm` (wsl) bundles declare
`requires_bundles: [databases/mysql, databases/redis]`, so selecting the web
stack auto-selects MySQL + Redis. PostgreSQL and the MS SQL driver are
independent — select them only if a project needs them.

## Uninstall tiers

`mysql` and `postgresql` carry `uninstall_tier: 3` (data-bearing — removal is
guarded); `redis` is tier 2; `mssql-driver` is tier 1. Database data is never
auto-removed (`rollback()` is intentionally a no-op).
