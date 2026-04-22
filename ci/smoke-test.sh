#!/usr/bin/env bash
# ci/smoke-test.sh — end-to-end smoke test for dev-bootstrap on Ubuntu 24.04.
#
# Builds a hermetic Docker image (see ci/Dockerfile.ubuntu-24.04) that mimics a
# fresh WSL Ubuntu install, then runs bootstrap.sh inside it non-interactively
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

IMAGE="dev-bootstrap-smoke"
LOGFILE="$HERE/last-run.log"
TIMEOUT_SECS="${TIMEOUT_SECS:-600}"

# Default SKIP list.
#
# 05-identity          — `gh auth login --web` needs a real TTY for the
#                        device-code flow. Mocking gh is out of scope; see
#                        ci/README.md for how to add coverage.
# 95-dotfiles-personal — clones a private repo over SSH. No credentials in
#                        the container.
#
# 60-web-stack / 70-remote-access / 90-editor are NOT in this list —
# they auto-skip because their INCLUDE_* opt-in vars default to 0. Letting
# bootstrap.sh's own gate handle them keeps that path exercised too.
DEFAULT_SKIP="05-identity 95-dotfiles-personal"
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
    echo >&2 "         INCLUDE_DOCKER=1 bash ~/dev-bootstrap/bootstrap.sh"
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
    echo >&2 "         INCLUDE_DOCKER=1 bash ~/dev-bootstrap/bootstrap.sh"
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
printf ' dev-bootstrap smoke test (Ubuntu 24.04)\n'
printf '==========================================\n\n'

printf '>>> building %s\n' "$IMAGE"
docker build "${BUILD_ARGS[@]}" \
    -t "$IMAGE" \
    -f ci/Dockerfile.ubuntu-24.04 \
    .

printf '\n>>> running bootstrap (SKIP_TOPICS="%s", timeout %ss)\n\n' \
    "$SKIP_TOPICS" "$TIMEOUT_SECS"

# Invocation mirrors the spec exactly: `bash -c "SKIP_TOPICS='…' NON_INTERACTIVE=1
# bash ~/dev-bootstrap/bootstrap.sh"`. We pass env vars inline (not via -e)
# so the shell inside the container sees them as a single-command prefix —
# same contract as a developer running the bootstrap by hand from a shell.
RUN_CMD="SKIP_TOPICS='$SKIP_TOPICS' NON_INTERACTIVE=1 bash ~/dev-bootstrap/bootstrap.sh"

start=$(date +%s)
# We write both stdout and stderr to the logfile AND to the terminal via tee.
# PIPESTATUS[0] recovers the docker-run exit code — tee itself always returns 0.
set +e
if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$TIMEOUT_SECS" \
        docker run --rm "$IMAGE" bash -c "$RUN_CMD" \
        2>&1 | tee "$LOGFILE"
else
    docker run --rm "$IMAGE" bash -c "$RUN_CMD" \
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
