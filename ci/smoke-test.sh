#!/usr/bin/env bash
# ci/smoke-test.sh — end-to-end smoke test for mesh-workstation on Ubuntu 24.04.
#
# Builds a hermetic Docker image (see ci/Dockerfile.ubuntu-24.04) that mimics a
# fresh WSL Ubuntu install, then runs setup.sh inside it non-interactively
# with a curated SKIP_TOPICS list. Prints SMOKE TEST PASSED / FAILED, writes
# the full run log to ci/last-run.log, and exits with the bootstrap's own
# exit code (or 124 on timeout).
#
# Usage: bash ci/smoke-test.sh [--no-cache]
#
# Environment knobs:
#   TIMEOUT_SECS=600    override the 10-minute hard cap
#   EXTRA_SKIP="..."    append topics to the default SKIP list
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT"

IMAGE="mesh-workstation-smoke"
LOGFILE="$HERE/last-run.log"
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"

# Default SKIP list.
#
# identity  — `gh auth login --web` needs a real TTY for the device-code flow.
#             Mocking gh is out of scope; see ci/README.md for how to add coverage.
# personal  — clones a private repo over SSH. No credentials in the container.
#
# web / remote-access opt-in bundles are NOT in this list — they auto-skip because
# their INCLUDE_* opt-in vars default to 0. Letting setup.sh's own gate handle them
# keeps that path exercised too.
# setup.sh honors SKIP_TOPICS by filtering the resolved selection (T-009 closed):
# both topics are dropped before the engine runs.
DEFAULT_SKIP="identity personal"
SKIP_TOPICS="${DEFAULT_SKIP}${EXTRA_SKIP:+ $EXTRA_SKIP}"

BUILD_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-cache) BUILD_ARGS+=("--no-cache") ;;
        --help|-h)
            sed -n '2,16p' "$0"
            exit 0
            ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo >&2 "error: docker CLI not found on PATH."
    echo >&2 "       install via the bootstrap's opt-in topic:"
    echo >&2 "         INCLUDE_DOCKER=1 bash ~/mesh-workstation/setup.sh"
    echo >&2 "       (or tick 'docker' in the interactive menu)"
    exit 127
fi

# Daemon reachability probe. `docker info` fails fast with a distinctive
# message when the caller can't read /var/run/docker.sock; the usual cause
# on WSL/Linux is "user was added to docker group but the current shell
# session still has the old group set" (group membership is inherited at
# login time). Fix by re-executing ourselves via `sg docker -c ...` which
# spawns a child with the new group applied — no relogin, no reboot.
if ! docker info >/dev/null 2>&1; then
    if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
        # Member per /etc/group but not yet in the session's effective
        # groups. Re-exec via sg, guarded by an env flag so we don't loop.
        if [[ "${SMOKE_SG_RELAUNCHED:-}" != "1" ]]; then
            echo ">>> docker socket not accessible in this shell — re-executing via 'sg docker'"
            echo ">>> (group 'docker' is yours per /etc/group but this shell predates that change)"
            exec sg docker -c "SMOKE_SG_RELAUNCHED=1 bash '$0' $*"
        fi
        echo >&2 "error: docker daemon still unreachable after sg docker relaunch."
        echo >&2 "       check: sudo systemctl status docker  (or: sudo service docker status)"
        exit 126
    fi
    echo >&2 "error: docker daemon unreachable and $USER is not in the docker group."
    echo >&2 "       fix via the bootstrap's opt-in topic:"
    echo >&2 "         INCLUDE_DOCKER=1 bash ~/mesh-workstation/setup.sh"
    exit 126
fi

# `timeout` is in coreutils — Mac might have it via `gtimeout` under coreutils
# brew. Fall back gracefully.
TIMEOUT_BIN="timeout"
if ! command -v timeout >/dev/null 2>&1; then
    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_BIN="gtimeout"
    else
        echo >&2 "warn: neither timeout nor gtimeout found — running without hard cap."
        TIMEOUT_BIN=""
    fi
fi

printf '==========================================\n'
printf ' mesh-workstation smoke test (Ubuntu 24.04)\n'
printf '==========================================\n\n'

# Preflight: assert the Dockerfile's target paths exist in the build
# context before invoking docker build. Saves ~30s of layered build
# noise when a path move silently invalidates the image (see Review A
# finding A3, where lib/detect-os.sh and bootstrap.sh slipped past
# review because docker build still appeared to "work").
preflight_paths=(
    scripts/lib/detect-os.sh
    setup.sh
)
for p in "${preflight_paths[@]}"; do
    if [[ ! -e "$ROOT/$p" ]]; then
        printf >&2 'preflight failed: %s missing in build context\n' "$p"
        printf >&2 '  (ci/Dockerfile.ubuntu-24.04 references it; refusing to build)\n'
        exit 2
    fi
done
printf '>>> preflight ok (%d Dockerfile targets exist)\n' "${#preflight_paths[@]}"

printf '>>> building %s\n' "$IMAGE"
docker build "${BUILD_ARGS[@]}" \
    -t "$IMAGE" \
    -f ci/Dockerfile.ubuntu-24.04 \
    .

printf '\n>>> running bootstrap (SKIP_TOPICS="%s", timeout %ss)\n\n' \
    "$SKIP_TOPICS" "$TIMEOUT_SECS"

# Invocation mirrors the spec exactly: `bash -c "SKIP_TOPICS='…' NON_INTERACTIVE=1
# bash ~/mesh-workstation/setup.sh"`. We pass env vars inline (not via -e)
# so the shell inside the container sees them as a single-command prefix —
# same contract as a developer running the bootstrap by hand from a shell.
#
# PHP_VERSIONS is pinned to a two-version subset in CI. The default (all
# versions from data/php-versions.conf) would spin up 4 versions × 4 PECL
# extensions = 16 builds. mongodb alone takes ~90s per build, pushing the
# run over the 600s GHA timeout. Two versions still exercise the
# per-version ABI isolation fix (lib/pecl-install.sh) — if that breaks,
# the second version fails and CI catches it. Full 4-version matrix
# belongs to a deferred Tier 3 E2E (SPEC §14).
: "${CI_PHP_VERSIONS:=8.4 8.5}"

# Item-level skips (MESH_SKIP_ITEMS, honored by the install engine — finer than
# the topic-level SKIP_TOPICS above). Override with CI_SKIP_ITEMS="" to exercise
# any of these locally. Two reasons an item lands here:
#
#   rust-bins-wsl — pulls dust/xh/procs from the GitHub-release CDN; a stalled
#     transfer there repeatedly hung this run to the hard timeout. Its bootstrap
#     logic is trivial (fetch + extract to ~/.local/bin) and the download path is
#     hardened separately, so we drop just this externally-dependent item rather
#     than hold the pipeline hostage to a third-party CDN.
#
#   mysql-wsl / redis-wsl / postgresql — database *servers*. Their install()
#     starts the daemon and verify() asserts it is running (systemctl/service),
#     but this hermetic container has no init system, so the server can never
#     come up and post-install verify can't pass. We validate the bootstrap, not
#     a live DB runtime — same rationale as the identity/personal topic skips.
#     (The apt-backed client/driver bits of each topic still install.)
#
#   mssql-driver — corporate MS SQL ODBC driver. Its verify() hard-requires the
#     PECL sqlsrv/pdo_sqlsrv extensions built for EVERY PHP version, but `pecl`
#     (php-pear) is not present in this image, so the build can't run and verify
#     can't pass. (Tracked separately: the php topic builds PECL extensions yet
#     nothing installs php-pear, so every PECL ext silently skips — a likely real
#     gap on fresh WSL too, deserving its own fix rather than a blind one here.)
#
#   service-convergence — WSL nginx/php-fpm activation via systemctl + socket
#     listeners. The hermetic image has no systemd PID 1, so php-fpm/nginx
#     never become active and the item cannot converge. Packages, mkcert, and
#     site templates still install; listener health is covered by
#     tests/integration/php-web-stack-convergence.test.sh.
: "${CI_SKIP_ITEMS:=rust-bins-wsl mysql-wsl redis-wsl postgresql mssql-driver service-convergence}"
RUN_CMD="SKIP_TOPICS='$SKIP_TOPICS' PHP_VERSIONS='$CI_PHP_VERSIONS' MESH_SKIP_ITEMS='$CI_SKIP_ITEMS' NON_INTERACTIVE=1 bash ~/mesh-workstation/setup.sh"
[[ -n "$CI_SKIP_ITEMS" ]] && printf '>>> skipping items (MESH_SKIP_ITEMS): %s\n' "$CI_SKIP_ITEMS"

start=$(date +%s)
# We write both stdout and stderr to the logfile AND to the terminal via tee.
# PIPESTATUS[0] recovers the docker-run exit code — tee itself always returns 0.
set +e
if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SECS" \
        docker run --rm -e GITHUB_TOKEN -e GH_TOKEN "$IMAGE" bash -c "$RUN_CMD" \
        2>&1 | tee "$LOGFILE"
else
    docker run --rm -e GITHUB_TOKEN -e GH_TOKEN "$IMAGE" bash -c "$RUN_CMD" \
        2>&1 | tee "$LOGFILE"
fi
rc=${PIPESTATUS[0]}
set -e

elapsed=$(( $(date +%s) - start ))

printf '\n--- summary ---\n'
printf 'elapsed: %ss\n' "$elapsed"
printf 'log:     %s\n' "$LOGFILE"

case "$rc" in
    0)
        printf 'SMOKE TEST PASSED\n'
        exit 0
        ;;
    124)
        printf 'SMOKE TEST FAILED — hit %ss timeout\n' "$TIMEOUT_SECS"
        exit 124
        ;;
    *)
        printf 'SMOKE TEST FAILED (bootstrap exit=%s)\n' "$rc"
        exit "$rc"
        ;;
esac
