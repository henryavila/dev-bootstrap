#!/usr/bin/env bash
# scripts/lib/template-check.sh — verify mesh-workstation/template/ ↔
# mesh-identity structural parity (spec §C16.1).
#
# Walks both trees; reports paths present in one without the other. Files
# under "skip namespaces" (personal/host-specific) are exempt in BOTH
# directions: parity is a structural contract, not a content contract.
#
# Skip namespaces (superset of §2.4 hard-pins + per-host data files):
#   PREFIXES: .git/, tests/, docs/, .ai/memory/, claude/, .claude/, npm/
#   EXACT:    codex/config.toml, git/gitconfig.local,
#             ssh/authorized_keys, ssh/config
#
# Exit codes:
#   0   parity (or hook installed successfully)
#   1   drift detected
#   2   usage error / missing repo
#
# Subcommands:
#   (no flag)        verify parity, print drift to stderr
#   --quiet          exit code only; no output
#   --install-hook   install $MESH_IDENTITY_DIR/.git/hooks/pre-commit
#
# Spec: §C16.1. Phase 6 Task 6.4.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS_ROOT="$(cd "$HERE/../.." && pwd)"
TEMPLATE_DIR="${MESH_TEMPLATE_DIR:-$WS_ROOT/template}"
IDENTITY_DIR="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"

_die()  { printf 'template-check: %s\n' "$*" >&2; exit 2; }
_info() { printf '==> %s\n' "$*"; }

QUIET=0

SKIP_PREFIXES=(
    ".git/"
    "tests/"
    "docs/"
    ".ai/memory/"
    ".ai/"
    ".atomic-skills/"
    "claude/"
    ".claude/"
    "npm/"
    "extensions/"
    "config/"
    # secrets/ holds git-crypt-encrypted per-user data + the per-user manifest;
    # encrypted blobs cannot have a public .example (unlike shareable-structure
    # files). Treated as per-user data like npm/ + config/. The shareable part —
    # an empty manifest — still ships as template/secrets/manifest.yaml.example.
    "secrets/"
)
SKIP_EXACT=(
    "codex/config.toml"
    "git/gitconfig.local"
    "ssh/authorized_keys"
    "ssh/config"
)

_is_skipped() {
    local rel="$1" p
    for p in "${SKIP_PREFIXES[@]}"; do
        [[ "$rel" == "$p"* ]] && return 0
    done
    for p in "${SKIP_EXACT[@]}"; do
        [[ "$rel" == "$p" ]] && return 0
    done
    # Identity .example scaffolds don't need double .example.example in template
    [[ "$rel" == *.example ]] && return 0
    return 1
}

_install_hook() {
    local hook_dir="$IDENTITY_DIR/.git/hooks"
    local hook="$hook_dir/pre-commit"
    local marker="Auto-installed by \`mesh template-check --install-hook\`"
    local mesh_bin="$WS_ROOT/bin/mesh"
    [[ -d "$IDENTITY_DIR/.git" ]] \
        || _die "$IDENTITY_DIR is not a git repo (no .git/) — init it first"
    [[ -x "$mesh_bin" ]] \
        || _die "$mesh_bin not executable; cannot bake into hook"
    mkdir -p "$hook_dir" \
        || _die "mkdir $hook_dir failed"
    # If an existing pre-commit hook is NOT one we wrote, refuse rather than
    # silently overwrite it. User must either back it up or merge intentionally.
    if [[ -e "$hook" ]] && ! grep -qF "$marker" "$hook" 2>/dev/null; then
        _die "$hook exists and is not managed by this script. Back it up (mv $hook $hook.bak-\$(date +%s)) then re-run, or merge our hook contents in by hand."
    fi
    # CP4 F-001: bake absolute mesh binary path + resolve identity dir at
    # commit-time via `git rev-parse --show-toplevel`. Drops the fragile
    # PATH/env-default chain that ran whichever `mesh` happened to be on
    # PATH against env.sh's default $HOME/mesh-identity fallback.
    cat > "$hook" <<HOOK || _die "write $hook failed"
#!/usr/bin/env bash
# Auto-installed by \`mesh template-check --install-hook\` (C16.1).
# Blocks commits that break mesh-identity ↔ mesh-workstation/template/ parity.
identity_root="\$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
if [[ -z "\$identity_root" ]]; then
    exit 0
fi
if ! MESH_IDENTITY_DIR="\$identity_root" "${mesh_bin}" template-check --quiet 2>/dev/null; then
    echo "ERROR: structural drift between mesh-identity and mesh-workstation/template/" >&2
    echo "" >&2
    echo "Run: ${mesh_bin} template-check" >&2
    echo "Then update \$MESH_WORKSTATION_DIR/template/ to match + commit there." >&2
    exit 1
fi
# Secrets layer: refuse to commit a Tier-2 secret in cleartext (fail-closed).
# No-op unless files under secrets/ are staged.
if ! MESH_IDENTITY_DIR="\$identity_root" "${mesh_bin}" secret guard; then
    echo "" >&2
    echo "Commit blocked by the secrets encryption guard (see above)." >&2
    echo "Run: ${mesh_bin} secret doctor" >&2
    exit 1
fi
HOOK
    chmod +x "$hook" \
        || _die "chmod +x $hook failed"
    _info "hook installed at $hook"
}

_print_help() {
    cat <<'EOF'
Usage: mesh template-check [--quiet] [--install-hook]

  (no flag)         Verify template/ ↔ identity structural parity.
                    Reports drift to stderr; exits 0 on parity, 1 on drift.
  --quiet           Exit code only; no output (used by the pre-commit hook).
  --install-hook    Install $MESH_IDENTITY_DIR/.git/hooks/pre-commit
                    invoking `mesh template-check --quiet`.

Env:
  MESH_TEMPLATE_DIR   template source (default $WS_ROOT/template)
  MESH_IDENTITY_DIR   identity dir    (default $HOME/mesh-identity)

Skip namespaces (no parity required, both directions):
  prefixes: .git/, tests/, docs/, .ai/memory/, claude/, .claude/, npm/
  exact:    codex/config.toml, git/gitconfig.local,
            ssh/authorized_keys, ssh/config
EOF
}

# ─── Parse args ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)         QUIET=1; shift ;;
        --install-hook)  _install_hook; exit 0 ;;
        -h|--help)       _print_help; exit 0 ;;
        *)               _die "unknown arg '$1' (try -h)" ;;
    esac
done

# ─── Verify dirs ─────────────────────────────────────────────────
[[ -d "$TEMPLATE_DIR" ]] || _die "template/ missing at $TEMPLATE_DIR"
[[ -d "$IDENTITY_DIR" ]] || _die "identity dir missing at $IDENTITY_DIR (set MESH_IDENTITY_DIR)"

# ─── Parity check ────────────────────────────────────────────────
drift=0
findings=()

# Forward: every identity file in non-skip paths must have <path>.example in template
while IFS= read -r -d '' f; do
    rel="${f#"$IDENTITY_DIR/"}"
    _is_skipped "$rel" && continue
    if [[ ! -f "$TEMPLATE_DIR/$rel.example" ]]; then
        findings+=("missing in template: $rel.example (identity has $rel)")
        drift=1
    fi
done < <(find "$IDENTITY_DIR" -type f -print0 2>/dev/null)

# Reverse: every .example in template must have counterpart in identity.
# README* and .keep are template-meta — never expected in identity.
while IFS= read -r -d '' ex; do
    rel="${ex#"$TEMPLATE_DIR/"}"
    rel_no_ex="${rel%.example}"
    _is_skipped "$rel_no_ex" && continue
    if [[ ! -f "$IDENTITY_DIR/$rel_no_ex" ]]; then
        findings+=("missing in identity: $rel_no_ex (template has $rel)")
        drift=1
    fi
done < <(find "$TEMPLATE_DIR" -type f -name '*.example' -print0 2>/dev/null)

if (( drift == 1 )) && (( QUIET == 0 )); then
    printf 'template-check: %s\n' "${findings[@]}" >&2
fi
exit "$drift"
