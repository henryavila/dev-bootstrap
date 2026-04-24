#!/usr/bin/env bash
# tests/integration/deploy-manifest-completeness.test.sh
#
# Regression: bug found 2026-04-24 across 3 machines.
#
# When a topic's templates/ directory has BOTH a DEPLOY manifest AND template
# files, deploy.sh follows ONLY the DEPLOY manifest — auto_map_name is bypassed
# entirely (see lib/deploy.sh:132-184). Adding a new template file without
# also listing it in DEPLOY makes it dead code: present in git, never deployed,
# silently ignored.
#
# Symptom: bashrc.d-60-web-stack.sh and zshrc.d-60-web-stack.sh existed as
# templates since commit 1bcb63d (2026-04-23 alias migration), but the DEPLOY
# manifest was not updated. None of ultron, mac, crc had the fragments
# deployed. Aliases art/artisan/srn/srp/ts/tip/tup/tssh were system-wide
# undefined despite the migration being marked "✅ shipped".
#
# This test enumerates every template file under topics/*/templates/ and
# verifies it is referenced in the corresponding DEPLOY manifest (when one
# exists). Templates whose name auto-maps cleanly (bashrc.d-*.sh,
# zshrc.d-*.sh, bin/*) are the highest-risk class — they look like they
# would auto-deploy but DEPLOY's existence overrides that.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

shopt -s nullglob

# Enumerate every topic with a templates/ dir
for topic_dir in "$ROOT"/topics/*/templates; do
    [[ -d "$topic_dir" ]] || continue
    topic_name="$(basename "$(dirname "$topic_dir")")"
    deploy_file="$topic_dir/DEPLOY"

    if [[ ! -f "$deploy_file" ]]; then
        # No manifest → auto_map_name applies, no orphan risk for the classes
        # it covers. Still skip (out-of-scope for THIS test).
        continue
    fi

    # Build set of files referenced as src in DEPLOY (left side of `=`)
    declare -A deploy_srcs=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        src="${line%%=*}"
        # trim
        src="${src#"${src%%[![:space:]]*}"}"
        src="${src%"${src##*[![:space:]]}"}"
        [[ -z "$src" ]] && continue
        deploy_srcs["$src"]=1
    done < "$deploy_file"

    # Walk every template file, check membership
    while IFS= read -r -d '' tmpl; do
        rel="${tmpl#"$topic_dir"/}"
        # Skip the DEPLOY file itself
        [[ "$rel" == "DEPLOY" ]] && continue
        # Skip docs / readme files inside templates/ (rare but harmless)
        case "$rel" in
            *.md|*.txt) continue ;;
        esac

        if [[ -n "${deploy_srcs[$rel]:-}" ]]; then
            pass "$topic_name: $rel listed in DEPLOY"
        else
            # Highlight high-risk auto-mapped names so the failure is actionable
            case "$rel" in
                bashrc.d-*.sh|zshrc.d-*.sh|bin/*)
                    fail "$topic_name: $rel exists but NOT listed in DEPLOY (auto-map suppressed by DEPLOY presence — fragment will never be deployed)"
                    ;;
                *)
                    fail "$topic_name: $rel exists but NOT listed in DEPLOY (orphan template)"
                    ;;
            esac
        fi
    done < <(find "$topic_dir" -mindepth 1 -type f -print0)

    unset deploy_srcs
done

summary
