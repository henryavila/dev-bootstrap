# GitHub Actions workflows

This directory holds the automated checks that run on every push and pull-request
against `main`. Keep them fast, deterministic, and independent of external secrets.

## Workflows

| File | Trigger | Purpose |
|------|---------|---------|
| [`lint.yml`](lint.yml) | push, PR | ShellCheck + `bash -n` on every script under `bootstrap.sh`, `lib/`, and `topics/` |
| [`smoke-test.yml`](smoke-test.yml) | push to `main`, PR to `main`, `workflow_dispatch` | End-to-end bootstrap smoke test on a fresh Ubuntu 24.04 runner via `ci/smoke-test.sh` |

### `lint.yml`

Static analysis only — no code runs. Uses `ludeeus/action-shellcheck` with
`severity: warning` and verifies that every tracked shell script parses under
`bash -n`. Typical runtime: < 30 s.

### `smoke-test.yml`

Exercises the happy path of `bootstrap.sh` inside a fresh `ubuntu-24.04` runner
to catch regressions that ShellCheck cannot see (missing packages, broken
installs, wrong ordering between topics).

**Runner:** `ubuntu-24.04` (pinned to match `ci/Dockerfile.ubuntu-24.04` used by
local reproduction).

**Timeout:** 15 minutes. Anything slower is a regression.

**Fail-soft harness check:** the first step checks that `ci/smoke-test.sh` and
`ci/Dockerfile.ubuntu-24.04` exist. If either is missing the workflow logs a
warning and skips the smoke step — this keeps `main` green while the CI harness
is being bootstrapped in parallel.

**Artifacts on failure:** on failure, `ci/logs/smoke-<run-id>.log` is uploaded
as a workflow artifact (`smoke-test-log-<run-id>`) with 14-day retention. Grab
it from the run page's *Artifacts* panel.

## Debugging a red build

1. Open the **Actions** tab on GitHub:
   <https://github.com/henryavila/dev-bootstrap/actions>
2. Click the failing run → click the red job → expand the failing step.
3. For `smoke-test.yml` failures, scroll to the bottom of the page and download
   the `smoke-test-log-<run-id>` artifact for the full log (including lines
   truncated by the GHA live viewer).
4. Re-run the failing job with **"Re-run failed jobs"** if you suspect a
   transient infra flake — but investigate the log first. Real regressions
   reproduce.

## Running locally before you push

You do not need to wait for GHA round-trips to catch issues:

```bash
# same checks as lint.yml
shellcheck $(find bootstrap.sh lib topics -name '*.sh')
find bootstrap.sh lib topics -name '*.sh' -exec bash -n {} \;

# same end-to-end check as smoke-test.yml (requires Docker)
bash ci/smoke-test.sh
```

See [`ci/README.md`](../../ci/README.md) for details on how the smoke-test
harness builds the Docker image and which topics are exercised.

## Secrets

None of the current workflows require repository secrets. If a future workflow
does, document the required secret name here and instruct maintainers to set it
under **Repository Settings → Secrets and variables → Actions**.
