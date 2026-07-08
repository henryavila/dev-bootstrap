# shellcheck shell=bash
# Driver: npx. Runs an npm package via npx without global install.
#
# spec format: "<package>[@version] <subcommand> [args...]"
#   e.g. "@henryavila/claudebar@latest install"
#         "@scope/tool config --flag"
#
# Detection model (2026-05-28):
#   npx leaves no on-disk footprint we can probe afterwards. Menu detection
#   is satisfied by the engine-level install marker
#   (~/.local/state/mesh/installed/<topic>__<name>.env, written by
#   install-engine.sh on successful install/verify). Drivers stay agnostic
#   of the marker; the scanner reads it directly.
#
# check():    returns 1 (always run). The engine's "skip if check passes"
#             gate does not apply to npx by design — most npx items are
#             intentionally run-every-time (atomic-skills, claudebar setup,
#             …). For items that need a "run once then skip" semantic, set
#             `check:` in items.yaml; manifest check overrides driver check.
# install():  runs `npx -y <spec>` (word-split intentional — spec carries
#             subcommand + args).
# verify():   extracts <package> from spec, runs `npx -y <package> doctor`.
#             If doctor exits non-zero or doesn't exist, trusts install.
# rollback(): extracts <package> from spec, runs `npx -y <package> uninstall`.
#             Best-effort — swallows failure if uninstall subcommand is absent.
#
# stdin:      every npx call runs with stdin detached (`</dev/null`). The engine
#             invokes drivers from a non-interactive per-item subshell; an
#             installer that prompts on a TTY hangs the whole bootstrap.
#             Detaching forces `process.stdin.isTTY=false`, so well-behaved
#             installers self-skip their prompts. Live failure: claude-mem
#             v13.8.0 added a "CMEM Online" email + "Overwrite existing
#             installation?" confirm — gated only on isTTY, not on the spec's
#             --ide/--provider/--runtime/--no-auto-start flags — which blocked
#             a fresh `claude-mem` install with no way to answer.

_npx_extract_package() {
    # First token of the spec is the package (possibly @scoped with @version).
    local spec="$1"
    printf '%s' "${spec%% *}"
}

# `npx` ships with Node. mesh installs Node via fnm (~/.local/share/fnm), whose
# shell activation the engine's non-interactive per-item subshell never runs — so
# on a FRESH bootstrap (Node installed earlier in the same run) `npx` is not yet
# on PATH and the item dies with rc 127 (the live CI-smoke symptom for claudebar).
# Activate the fnm-managed default Node so npx resolves, mirroring
# topics/languages/node-fnm.sh. No-op when npx is already on PATH (brew/apt Node,
# or a shell that already activated fnm). Best-effort: returns npx's availability.
_npx_ensure_on_path() {
    command -v npx >/dev/null 2>&1 && return 0
    if ! command -v fnm >/dev/null 2>&1 && [[ -x "$HOME/.local/share/fnm/fnm" ]]; then
        PATH="$HOME/.local/share/fnm:$PATH"; export PATH
    fi
    if command -v fnm >/dev/null 2>&1; then
        # `fnm use` needs FNM_MULTISHELL_PATH from `fnm env`; node-fnm.sh sets a
        # default version at install, so activating it puts node/npx/npm on PATH.
        eval "$(fnm env 2>/dev/null || true)"
        fnm use default >/dev/null 2>&1 || true
    fi
    command -v npx >/dev/null 2>&1
}

npx_check() { return 1; }

# shellcheck disable=SC2086  # intentional word-split: spec carries subcommand + args
npx_install() { _npx_ensure_on_path || true; npx -y $1 </dev/null; }

# shellcheck disable=SC2086
npx_repair() { _npx_ensure_on_path || true; echo "npx: re-running $1 (repair)" >&2; npx -y $1 </dev/null; }

npx_verify() {
    local pkg
    pkg="$(_npx_extract_package "$1")"
    _npx_ensure_on_path || true
    npx -y "$pkg" doctor </dev/null 2>/dev/null || return 0
}

npx_rollback() {
    local pkg
    pkg="$(_npx_extract_package "$1")"
    _npx_ensure_on_path || true
    npx -y "$pkg" uninstall </dev/null 2>/dev/null || true
}

# Version-aware update (T-600): npx has no installed version to diff, so re-run
# the spec — `npx -y` fetches the latest matching the spec (a pinned @version is
# a no-op; @latest / unpinned picks up new releases). Same word-split as install.
# shellcheck disable=SC2086
npx_update() { _npx_ensure_on_path || true; echo "npx: re-running $1 (latest)" >&2; npx -y $1 </dev/null; }
