#!/usr/bin/env bash
# tests/integration/services.test.sh
#
# Contract suite for `mesh services` (initiative mesh-services) — the unified,
# cross-platform service control plane (2-bit model: active × enabled).
#
# Built TDD across T-001..T-006; this file is the deterministic exit-gate
# (G-1 / G-3). It grows one block per task. Current coverage:
#
#   T-001 — the service registry: bash descriptor modules in
#           scripts/lib/services/registry/<id>.sh + the aggregator
#           scripts/lib/services/registry.sh that resolves them for the
#           current OS into machine-readable rows
#               id|display|aliases|owner|kind|scope|target
#           OS is stubbed via MESH_SERVICES_OS (mirrors clean's MESH_CLEAN_OS);
#           the descriptor dir is swapped via MESH_SERVICES_REGISTRY_DIR
#           (mirrors MESH_CLEANERS_DIR) so edge cases use hermetic fixtures.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
AGG="$REPO_ROOT/scripts/lib/services/registry.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-services.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# Resolve the registry for a stubbed OS against the REAL shipped descriptors.
resolve() { MESH_SERVICES_OS="$1" NO_COLOR=1 bash "$AGG"; }
# Same, but against a hermetic fixture descriptor dir.
resolve_in() { MESH_SERVICES_OS="$1" MESH_SERVICES_REGISTRY_DIR="$2" NO_COLOR=1 bash "$AGG"; }

# ─── T-001 ───────────────────────────────────────────────────────────────────

# ─── Case 1: WSL resolves curated services to their systemd units ────────────
out="$(resolve wsl 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 1a: aggregator exits 0 on wsl"
assert_contains "$out" "mysql|MySQL|mysqld|databases|systemd|system|mysql" \
    "Case 1b: mysql resolves to the wsl systemd system unit (full row)"
assert_contains "$out" "redis|Redis|redis-server|databases|systemd|system|redis-server" \
    "Case 1c: redis resolves to the wsl systemd unit redis-server (apt pkg name)"

# ─── Case 2: mac resolves the same services to their brew formulae ───────────
out="$(resolve mac 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 2a: aggregator exits 0 on mac"
assert_contains "$out" "mysql|MySQL|mysqld|databases|brew||mysql" \
    "Case 2b: mysql resolves to the mac brew formula (empty scope)"
assert_contains "$out" "redis|Redis|redis-server|databases|brew||redis" \
    "Case 2c: redis resolves to the mac brew formula"

# ─── Case 3: native Linux falls back to the systemd (wsl) mapping ────────────
out="$(resolve linux 2>&1)"; rc=$?
assert_eq "$rc" 0 "Case 3a: aggregator exits 0 on linux"
assert_contains "$out" "mysql|MySQL|mysqld|databases|systemd|system|mysql" \
    "Case 3b: linux reuses the systemd mapping (no dedicated linux fn)"

# ─── Case 4: hermetic fixtures — skip _-prefixed, skip missing-meta, omit ────
#            services with no descriptor for the requested OS.
FIX="$SANDBOX/reg"
mkdir -p "$FIX"
cat >"$FIX/good.sh" <<'EOF'
# shellcheck shell=bash
svcdef_good_meta() { echo "Good|g|testtopic"; }
svcdef_good_wsl()  { echo "systemd|system|goodunit"; }
EOF
cat >"$FIX/_helper.sh" <<'EOF'
# shellcheck shell=bash
svcdef__helper_meta() { echo "Helper|h|nope"; }
EOF
cat >"$FIX/nometa.sh" <<'EOF'
# shellcheck shell=bash
svcdef_nometa_wsl() { echo "systemd|system|nometaunit"; }
EOF

out="$(resolve_in wsl "$FIX" 2>/dev/null)"; rc=$?
assert_eq "$rc" 0 "Case 4a: aggregator exits 0 over a fixture dir"
assert_contains "$out" "good|Good|g|testtopic|systemd|system|goodunit" \
    "Case 4b: a well-formed fixture descriptor resolves"
assert_not_contains "$out" "_helper" "Case 4c: _-prefixed files are not treated as services"
assert_not_contains "$out" "nometa"  "Case 4d: a module missing svcdef_<id>_meta is skipped"

out_mac="$(resolve_in mac "$FIX" 2>/dev/null)"
assert_not_contains "$out_mac" "good|" "Case 4e: a service with no descriptor for the OS is omitted"

# ─── Case 5: the missing-meta skip warns on STDERR, never corrupting stdout ──
err="$(resolve_in wsl "$FIX" 2>&1 1>/dev/null)"
assert_contains "$err" "nometa" "Case 5: missing-meta module is reported on stderr"

summary
