# shellcheck shell=bash
# Service descriptor: postgres — PostgreSQL server, one logical service per
# installed cluster (databases topic). DYNAMIC: svcdef_postgres_enumerate expands
# it into postgres@<ver>-<cluster> rows so boot-state is controlled at the unit
# systemd actually autostarts — postgresql@<ver>-<cluster>.service. The bare
# `postgresql` meta-unit does NOT govern per-cluster autostart, so the enumerated
# instance is the correct enable/disable target. Mirrors php-fpm (T-005).
#   wsl → systemd units postgresql@<ver>-<cluster>, from /etc/postgresql/*/*.
#   mac → brew formulae postgresql@<ver>, from `brew list --formula`.
# Opt-out at boot on WSL by default (T-006): kept installed but not autostarted
# unless the host's services.default.<alias> opts it in.
svcdef_postgres_meta()   { echo "PostgreSQL|psql,pg,postgresql|databases"; }

# Static fallback mapping (emitted only when enumerate finds no cluster): the
# bare meta-unit. kind|scope is shared by every enumerated instance.
svcdef_postgres_wsl()    { echo "systemd|system|postgresql"; }
svcdef_postgres_mac()    { echo "brew||postgresql"; }
svcdef_postgres_optout() { echo "wsl"; }

# svcdef_postgres_enumerate <os> — emit `id|display|target` per installed cluster
# (wsl) / versioned formula (mac); the aggregator merges aliases/owner + kind/
# scope from the mapping above. Empty output ⇒ the static single row.
#   wsl/linux: glob ${MESH_PG_DIR:-/etc/postgresql}/<ver>/<cluster>
#              → systemd unit postgresql@<ver>-<cluster> (the install-postgres.sh
#                unit name: postgresql@${POSTGRES_VERSION}-${cluster})
#   mac:       brew list --formula | grep '^postgresql@<ver>' → formula postgresql@<ver>
svcdef_postgres_enumerate() {
    local os="$1" root ver cluster d formula
    case "$os" in
        wsl|linux)
            root="${MESH_PG_DIR:-/etc/postgresql}"
            for d in "$root"/*/*; do
                [[ -d "$d" ]] || continue
                cluster="$(basename "$d")"
                ver="$(basename "$(dirname "$d")")"
                printf 'postgres@%s-%s|PostgreSQL %s/%s|postgresql@%s-%s\n' \
                    "$ver" "$cluster" "$ver" "$cluster" "$ver" "$cluster"
            done
            ;;
        mac)
            while IFS= read -r formula; do
                [[ -n "$formula" ]] || continue
                ver="${formula#postgresql@}"
                printf 'postgres@%s|PostgreSQL %s|%s\n' "$ver" "$ver" "$formula"
            done < <(brew list --formula 2>/dev/null | grep -oE '^postgresql@[0-9]+$' | sort -V)
            ;;
    esac
}
