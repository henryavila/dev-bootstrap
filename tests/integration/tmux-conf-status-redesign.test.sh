#!/usr/bin/env bash
# tests/integration/tmux-conf-status-redesign.test.sh — pin the two-line
# status redesign + interaction fixes in the tmux.conf template.
#
# Design + live validation trail: mesh-identity
# .ai/analysis/2026-06-09-tmux-interface-redesign.md (proposals A/B/F2/G,
# approved 2026-06-09). The contract:
#   A — window tabs honor manual rename (`prefix ,`), show app titles only
#       when meaningful (≠ hostname), strip "user@host: " prefixes from
#       remote-shell titles (host never lives in a tab), truncate at 24.
#   B — `prefix c` (and the right-click menu) preserve the pane cwd.
#   F2 — right-click in a pane always opens a tmux menu, even when a
#        fullscreen TUI (Claude Code) grabbed mouse reporting.
#   G — status is 2 lines: line 1 = windows only, line 2 = context strip
#       ([session] cwd git ⚡C-a flags host+time-only-in-alternate-screen).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

CONF="$REPO_ROOT/topics/shell-terminal/templates/tmux/tmux.conf"

assert_file_exists "$CONF" "tmux.conf template exists"

# ── A · smart window tab text ───────────────────────────────────────────────
for var in '@catppuccin_window_default_text' '@catppuccin_window_current_text'; do
    assert_pattern_present "$CONF" "set -g $var" \
        "A — overrides $var before TPM loads the theme"
done
assert_pattern_present "$CONF" 'automatic-rename},on' \
    "A — tab text branches on automatic-rename (manual rename wins)"
# Literal ERE escaping of the strip expression is unreadable; pin the two
# halves that matter — the user@host strip head and the 24-col truncation.
assert_pattern_present "$CONF" 's/\^\[\^@ ' \
    "A — strips user@host: prefix from app titles (host never in a tab)"
assert_pattern_present "$CONF" '=\|24\|…:pane_title' \
    "A — app titles truncated at 24 cols with ellipsis"
assert_pattern_absent "$CONF" '_text " #T"' \
    "A — raw #T-only tab text is gone (root cause of 'rename does not work')"

# ── B · cwd preserved on new windows ────────────────────────────────────────
assert_pattern_present "$CONF" 'bind c new-window -c "#{pane_current_path}"' \
    "B — prefix c opens new window at the pane cwd"

# ── F2 · right-click menu always wins ───────────────────────────────────────
assert_pattern_present "$CONF" 'bind-key -T root MouseDown3Pane display-menu' \
    "F2 — MouseDown3Pane rebound to display-menu (no mouse_any_flag gate)"
assert_pattern_present "$CONF" '"Rename Window"' \
    "F2 — custom menu carries Rename Window"

# ── G · two-line status ─────────────────────────────────────────────────────
assert_pattern_present "$CONF" 'set -g status 2' \
    "G — status bar is two lines"
assert_pattern_present "$CONF" 'set -g status-left ""' \
    "G — line 1 carries windows only (status-left emptied)"
assert_pattern_present "$CONF" 'set -g status-right ""' \
    "G — line 1 carries windows only (status-right emptied)"
assert_pattern_present "$CONF" '@mesh_line2_left' \
    "G — line 2 left segment defined"
assert_pattern_present "$CONF" '@mesh_line2_right' \
    "G — line 2 right segment defined"
# Host+clock shows only while the prompt is hidden (foreground command is
# not a shell). alternate_on was too narrow: Claude Code inline mode hides
# the prompt without the alternate screen.
assert_pattern_present "$CONF" 'm/r:\^\(zsh\|bash\|fish\|sh\)' \
    "G — host+time gated on prompt-hidden (foreground ≠ shell)"
assert_pattern_absent "$CONF" '@mesh_line2.*alternate_on' \
    "G — alternate_on gate removed (missed Claude Code inline mode)"
assert_pattern_present "$CONF" 'client_width' \
    "G — responsive cuts for phone-width clients (Moshi/mosh)"
assert_pattern_present "$CONF" 'client_prefix' \
    "G — prefix-pressed indicator present"
assert_pattern_present "$CONF" '@mesh_home' \
    "G — \$HOME resolved at load for the ~-abbreviated cwd"
assert_pattern_present "$CONF" 'status-format\[1\]' \
    "G — second status line format installed"
# Regression guard: #{T:...} strftime's the whole line INCLUDING #() command
# text — a printf "%s" inside the git fragment rendered as the epoch.
assert_pattern_absent "$CONF" '@mesh_line2.*printf' \
    "G — line 2 segments never use printf (strftime eats %-sequences)"

# ── H · nested cockpit: auto-hide outer bar + manual toggle ─────────────────
assert_pattern_present "$CONF" 'set -g focus-events on' \
    "H — focus-events enabled (hooks + nvim autoread)"
for hook in 'pane-focus-in' 'session-window-changed' 'window-pane-changed'; do
    assert_pattern_present "$CONF" "set-hook -g $hook .*m/r:\^\(ssh\|mosh\)" \
        "H — $hook hook re-evaluates the ssh/mosh auto-hide rule"
done
assert_pattern_present "$CONF" 'bind b if -F' \
    "H — prefix b manually flips the bar (key verified unbound in stock tmux)"

# ── Functional: the conf parses and applies on a scratch server ─────────────
if command -v tmux >/dev/null 2>&1; then
    SOCK="mesh-conf-test-$$"
    # -f loads ONLY the template (no user conf); new-session reports config
    # parse errors on stderr and still starts — capture both.
    err="$(tmux -L "$SOCK" -f "$CONF" new-session -d -s probe 2>&1)"
    assert_eq "" "$err" "functional — template parses with zero errors"

    assert_eq "status 2" "$(tmux -L "$SOCK" show -g status 2>/dev/null)" \
        "functional — status resolves to 2 lines"
    rclick="$(tmux -L "$SOCK" list-keys -T root MouseDown3Pane 2>/dev/null)"
    assert_contains "$rclick" 'display-menu' \
        "functional — right-click binding active"
    # The stock binding also calls display-menu but only behind the
    # mouse_any_flag forward-to-app gate — the redesign removes the gate.
    assert_not_contains "$rclick" 'mouse_any_flag' \
        "functional — right-click menu NOT gated on mouse_any_flag"
    assert_contains \
        "$(tmux -L "$SOCK" show -g 'status-format[1]' 2>/dev/null)" \
        '@mesh_line2_left' \
        "functional — line 2 format references the left segment"

    tmux -L "$SOCK" kill-server 2>/dev/null || true
else
    echo "SKIP functional checks — tmux not installed" >&2
fi

summary
