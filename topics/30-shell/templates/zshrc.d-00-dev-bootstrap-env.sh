# shellcheck shell=bash
# ~/.zshrc.d/00-dev-bootstrap-env.sh — global dev-bootstrap feature defaults.

# Hard kill switch for dormant auto-main. This fragment loads before
# ~/.zshrc.d/40-tmux.sh, including older deployed copies whose own default was
# opt-out instead of opt-in.
export DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0
