# tests/

Smoke tests for dev-bootstrap infrastructure. Not exhaustive — these
exercise specific behaviors that past regressions taught us to guard
against.

## Running

```bash
bash tests/deploy-smoke.sh
```

Exit code 0 on all pass, 1 on any failure.

Requires: `bash` 3.2+, `envsubst` (gettext), standard POSIX utilities.
Safe: all fixtures live in a temp dir; `$HOME` is redirected so nothing
outside the tmpdir is touched.

## Current tests

### `deploy-smoke.sh`

Covers `lib/deploy.sh`:

1. `${BREW_PREFIX}` envsubst in `.template` files.
2. Empty `BREW_PREFIX` degrades to empty string (Linux without brew).
3. Refuse overwrite of file without "managed by dev-bootstrap" marker.
4. `ALLOW_OVERWRITE_UNMANAGED=1` escape hatch works + creates backup.
5. Refuse templates with `.local` suffix.
6. `.bashrc.d/` fragments overwrite without the marker check (by design —
   fragment dirs are bootstrap-owned by convention).
7. `prune_backups` retains 5 newest + 1 oldest (protects archaeological
   root).

## Adding tests

Follow the pattern in `deploy-smoke.sh`:

- Each test gets its own fixture via `new_fixture`.
- `$HOME` is always a fake path inside the tmpdir.
- Use `assert`, `assert_file_contains`, or direct comparisons —
  accumulate `pass_count` / `fail_count` so the final summary is useful.
- No external network access; no tools outside bash/envsubst.

## What these tests are NOT

- Not a full integration test of bootstrap.sh end-to-end.
- Not a test of individual topics (install.*.sh scripts).
- Not a cross-OS matrix (run locally on whatever dev machine you're on;
  CI can later run it on matrix'd Linux + macOS if needed).
