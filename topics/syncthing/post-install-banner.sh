#!/usr/bin/env bash
# Custom item: Syncthing post-install pairing banner (spec §11 / D-10).
#
# The apply phase blocks here so the manual device-pairing step cannot be
# silently skipped: it prints the admin URL + next steps, then waits for Enter
# on the controlling tty. Pure echo + read — zero side effects, marked
# `idempotent: true` in the manifest so it runs on every apply.
#
# In --non-interactive runs (NON_INTERACTIVE=1) it only prints and does NOT
# block on read.

SYNCTHING_URL="${SYNCTHING_GUI_URL:-http://127.0.0.1:8384}"

check() {
    # Idempotent banner — never "already done"; the engine always re-runs it
    # (manifest idempotent: true). Returning 1 keeps the contract honest even
    # if the idempotent flag were dropped.
    return 1
}

install() {
    cat <<BANNER

  ┌─ Syncthing pairing ────────────────────────────────────────────┐
   Admin UI:  $SYNCTHING_URL
   Next steps:
     1. Open the admin UI and set a GUI username/password.
     2. Add this machine's other devices (Actions → Show ID to copy,
        then Add Remote Device on each peer — IDs must match both ways).
     3. Share the folders you want to converge (e.g. curated ~/.claude).
  └────────────────────────────────────────────────────────────────┘

BANNER
    if [ "${NON_INTERACTIVE:-0}" = "1" ]; then
        echo "  [non-interactive] skipping pairing pause — finish the steps above later."
        return 0
    fi
    if [ -e /dev/tty ]; then
        # shellcheck disable=SC2162
        read -p "  Press Enter once devices are paired… " _ </dev/tty || true
    fi
}

verify() {
    return 0
}

rollback() {
    :
}
