#!/usr/bin/env bash
# Unit tests for the interactive-prompt module in scripts/lib/log.sh:
#   - blink-styled prompt fields (a field awaiting input must blink)
#   - pure y/N decision (_confirm_decide)
#   - presence of the reusable prompt API
# The interactive reads themselves (ask_line/ask_secret) need a TTY and are
# validated at runtime — here we test the pure logic + the visual contract.
# Bash 3.2 compatible.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$WS/scripts/lib/log.sh"

pass=0; fail=0; fails=""
good() { pass=$((pass + 1)); }
no()   { fail=$((fail + 1)); fails="$fails
  FAIL: $1"; }

# --- _confirm_decide: pure y/N resolution ---
_confirm_decide y   n && good || no "explicit y → yes"
_confirm_decide yes n && good || no "yes → yes"
_confirm_decide ""  y && good || no "blank honours default y"
if _confirm_decide "" n; then no "blank default n should be no"; else good; fi
if _confirm_decide n  y; then no "explicit n should override default y"; else good; fi
if _confirm_decide xx n; then no "garbage should be no"; else good; fi

# --- _prompt_styled: colored caret marks the field, but NO blink + plain label ---
styled="$(_prompt_styled on 'Your name')"
case "$styled" in *$'\033'*) good ;; *) no "_prompt_styled on emits colour" ;; esac
case "$styled" in *$'\033[5m'*) no "_prompt_styled on must NOT blink (fights typing)" ;; *) good ;; esac
case "$styled" in *"❯"*) good ;; *) no "_prompt_styled on uses the ❯ caret" ;; esac
case "$styled" in *"Your name"*) good ;; *) no "_prompt_styled shows the label" ;; esac
# plain mode (no tty / NO_COLOR): caret + label, no escape codes
plain="$(_prompt_styled off 'Your name')"
case "$plain" in *$'\033'*) no "_prompt_styled off must not emit escapes" ;; *) good ;; esac
case "$plain" in *"Your name"*) good ;; *) no "_prompt_styled off still shows the label" ;; esac

# --- prompt_field writes to MESH_PROMPT_OUT and respects NO_COLOR ---
tmpout="$(mktemp)"
MESH_PROMPT_OUT="$tmpout" NO_COLOR=1 prompt_field 'Email'
case "$(cat "$tmpout")" in *$'\033'*) no "prompt_field NO_COLOR must be plain" ;; *) good ;; esac
case "$(cat "$tmpout")" in *"Email"*) good ;; *) no "prompt_field wrote the label to MESH_PROMPT_OUT" ;; esac
rm -f "$tmpout"

# --- reusable API is exported ---
for fn in ask_line ask_secret confirm ask_secret_or_skip pause ask_select prompt_field _prompt_tui_ok; do
    command -v "$fn" >/dev/null 2>&1 && good || no "$fn is defined (reusable)"
done

# --- ask_select bash fallback: numbered menu maps the number back to its id ---
tin="$(mktemp)"; tselout="$(mktemp)"
sel() { MESH_PROMPT_TUI=off MESH_PROMPT_IN="$tin" MESH_PROMPT_OUT="$tselout" \
    ask_select 'Pick' star 'mesh=A few' 'star=Many'; }
printf '1\n' > "$tin"; [ "$(sel)" = mesh ] && good || no "ask_select '1' → first id (mesh)"
printf '2\n' > "$tin"; [ "$(sel)" = star ] && good || no "ask_select '2' → second id (star)"
printf '\n'  > "$tin"; [ "$(sel)" = star ] && good || no "ask_select empty → default id (star)"
printf '9\n' > "$tin"; [ "$(sel)" = star ] && good || no "ask_select out-of-range → default id"
printf 'x\n' > "$tin"; [ "$(sel)" = star ] && good || no "ask_select non-numeric → default id"
rm -f "$tin" "$tselout"

# --- blink-tui bridge: the standard off-switches force the bash fallback ---
if ( MESH_PROMPT_TUI=off _prompt_tui_ok ); then no "MESH_PROMPT_TUI=off must disable the TUI"; else good; fi
if ( NON_INTERACTIVE=1 _prompt_tui_ok ); then no "NON_INTERACTIVE=1 must disable the TUI"; else good; fi
if ( MESH_PROMPT_OUT=/tmp/x _prompt_tui_ok ); then no "MESH_PROMPT_OUT must pin the bash path"; else good; fi
if ( MESH_PROMPT_IN=/tmp/x _prompt_tui_ok ); then no "MESH_PROMPT_IN must pin the bash path"; else good; fi

# --- summary ---
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'prompt.test.sh: %d/%d PASS\n' "$pass" "$total"
    exit 0
else
    printf 'prompt.test.sh: %d/%d PASS, %d FAIL%b\n' "$pass" "$total" "$fail" "$fails"
    exit 1
fi
