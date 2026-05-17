# scripts/lib/topic-configs.sh — workstation default config linker.
#
# Single source of truth for the C15 "ship default configs" mechanism
# introduced in Phase 3 Task 3.5 (commit f7dad21). Was originally
# duplicated across topics/20-terminal-ux/install.mac.sh,
# topics/50-git/install.sh, and topics/90-editor/install.sh (Review B
# finding B5). Centralized here so:
#   - Symlink semantics live in one place (Review B finding B4 fix).
#   - Future config additions touch one helper.
#
# Usage (from a topic install.sh):
#
#     # shellcheck source=../../scripts/lib/topic-configs.sh
#     source "$HERE/../../scripts/lib/topic-configs.sh"
#     link_default_config "$HERE/configs/p10k.zsh" "$HOME/.p10k.zsh"
#     link_default_config "$HERE/configs/btop/btop.conf" "$HOME/.config/btop/btop.conf"
#
# Semantics (in order):
#   1. Source must exist; otherwise warn + no-op (caller error, not fatal).
#   2. If destination is ALREADY a symlink to OUR source → no-op (idempotent).
#   3. If destination exists (any kind: real file, symlink-to-elsewhere,
#      directory) → no-op. "First writer wins" — workstation ships the
#      default; identity / user overrides keep what they already deployed.
#      This is the corrected semantics; the previous version blocked only
#      real files and clobbered user symlinks pointing elsewhere.
#   4. Otherwise → mkdir parent + ln -sf src dst.
#
# Caller responsibilities:
#   - Topic install.sh must source ../../scripts/lib/log.sh BEFORE this
#     file so `warn`/`ok` are defined. We don't source log.sh here to
#     avoid double-source side effects when multiple topics chain.
#   - Caller resolves $HERE before sourcing.
#
# Bash 3.2 compatible (macOS default).

link_default_config() {
    local src="$1" dst="$2"
    [[ -f "$src" ]] || { warn "C15: source missing: $src"; return 0; }

    # Tier 1 — already our link.
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
        return 0
    fi

    # Tier 2 — any existing destination wins, including symlinks pointing
    # elsewhere (e.g., a user / stow / identity-symlink deployment). This
    # respects identity-via-symlink workflows that the original
    # `[[ ! -L "$dst" ]]` guard silently clobbered.
    if [[ -e "$dst" ]] || [[ -L "$dst" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$dst")"
    ln -sf "$src" "$dst"
    ok "C15 default linked: $dst → $src"
}
