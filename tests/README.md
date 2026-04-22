# tests/

Test suite for dev-bootstrap. Catches regressions in the layers we
already shipped (mostly shell + templates), with zero external
dependencies beyond what the project already needs (`bash`, `envsubst`,
`jq`, `sort -V`).

## Running

```bash
bash tests/run-all.sh              # run every *.test.sh + deploy-smoke.sh
bash tests/run-all.sh unit         # only tests under tests/unit/
bash tests/run-all.sh cli/php      # any test whose path contains "cli/php"
VERBOSE=1 bash tests/run-all.sh    # don't suppress per-test stdout
```

Exit code is 0 if every file passes, 1 if any fails. Failed files print
their full output so CI / terminals point at the line causing the regression.

## Layout

```
tests/
├── run-all.sh                 ← orchestrator: discovery + aggregation
├── lib/
│   └── assert.sh              ← assertion helpers (source this in every test)
├── unit/
│   └── menu.test.sh           ← should_show_menu env-var gates + data/ parsing
├── integration/
│   ├── lint.test.sh           ← bash -n every shell + jq parse every .json
│   └── templates.test.sh      ← envsubst renders every .template cleanly;
│                                verifies ENVSUBST_ALLOWLIST covers every
│                                ${VAR} referenced by templates
├── cli/
│   ├── php-use.test.sh        ← --help / --list / --current / missing version
│   ├── link-project.test.sh   ← default mode validation, --list empty branch
│   └── share-project.test.sh  ← graceful degrade when ngrok absent
└── deploy-smoke.sh            ← preserved legacy smoke test (envsubst,
                                  managed-by marker, prune_backups, .local guard)
```

## Writing a new test

1. Create `tests/<area>/<name>.test.sh` (executable).
2. Source the assertions:
   ```bash
   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   source "$HERE/../lib/assert.sh"   # adjust depth as needed
   ```
3. Use the helpers:
   ```bash
   assert_eq      "$actual"  "$expected"    "descriptive message"
   assert_true    "some-command"
   assert_exit_code  0       "cmd --help"
   assert_contains  "$out"   "expected substring"
   assert_file_exists "/path/to/thing"
   ```
4. End with `summary` so the runner gets the correct exit code.

The helpers accumulate `PASS` and `FAIL` counters — tests don't abort on
the first failure (better signal in CI: you see all 7 missing pieces
instead of just the first).

## Guardrails

- **No sudo**: every test runs as a regular user. Branches requiring
  root (`sudo apt install`, `update-alternatives --set`, nginx reload,
  Valet install) are intentionally NOT exercised — they live in the
  `ci/smoke-test.sh` Docker harness instead.
- **No system side effects**: fixtures live under `mktemp -d`, `$HOME`
  is overridden where relevant, `trap ... EXIT` handles cleanup.
- **No network**: PECL installs, brew/apt, ngrok tunnels, GitHub API
  calls are all mocked or skipped. A broken internet never fails the suite.

## What's covered today (cross-reference)

| Layer | Covered | How |
|---|---|---|
| `lib/deploy.sh` — envsubst + marker | ✓ | `deploy-smoke.sh` (7 scenarios) |
| `lib/menu.sh` — automation gates | ✓ | `unit/menu.test.sh` (12 env vars) |
| `data/php-versions.conf` parses | ✓ | `unit/menu.test.sh` |
| `data/php-extensions-pecl.txt` structure | ✓ | `unit/menu.test.sh` |
| Shell syntax (every `*.sh` + shell template) | ✓ | `integration/lint.test.sh` |
| JSON syntax (every `*.json`) | ✓ | `integration/lint.test.sh` |
| Templates render with `ENVSUBST_ALLOWLIST` | ✓ | `integration/templates.test.sh` |
| `ENVSUBST_ALLOWLIST` covers every `${VAR}` in templates | ✓ | `integration/templates.test.sh` |
| `php-use` CLI contract | ✓ | `cli/php-use.test.sh` |
| `link-project` default + --list | ✓ | `cli/link-project.test.sh` |
| `share-project` graceful fail without ngrok | ✓ | `cli/share-project.test.sh` |
| Full bootstrap end-to-end (real packages) | ✓ | `ci/smoke-test.sh` (Docker, ~150s) |

## What's NOT covered (out of scope for this suite)

- Actual package installs (`apt install php8.5`, `brew install mysql@8.0`).
  Those live in `ci/smoke-test.sh` (Docker harness, runs in GHA) and
  the interactive real-machine runs.
- nginx config validation against a running nginx (would need root +
  real nginx). `templates.test.sh` catches structural issues; `sudo
  nginx -t` post-deploy catches the rest.
- Cross-machine syncthing convergence (phase 5/6 of the Claude Sync
  playbook — tested manually by design).
- `powershell.exe` interop on WSL (can't run from Linux-only CI;
  fallback-path test lives in the actual installer logic now).

## Past regressions we now guard against

Each bug below produced a test so it can't come back silently:

- `30-shell` template overwrote user `.zshrc` with custom Homebrew block
  → `deploy-smoke.sh` enforces managed-by marker.
- `lib/deploy.sh` forgot `ENVSUBST_ALLOWLIST` extension for
  `NGINX_SNIPPET_DIR` et al. → `integration/templates.test.sh` catches
  any template that references a non-allowlisted var.
- `share-project` could print help and still exit 0 when ngrok is
  missing → `cli/share-project.test.sh` locks the non-zero exit.
- `should_show_menu` used to miss newer `INCLUDE_*` vars → `unit/menu.test.sh`
  enumerates all 12 gates.
