#!/usr/bin/env bash
# scripts/lib/mach-o-resolvable.sh — assert every dynamic-library load command of
# a Mach-O binary resolves on disk. macOS-only STATIC dependency probe (no exec).
#
# WHY: `brew list <formula>` returns 0 while a downstream formula is silently
# broken after a dependency major-version bump (the live mosh case: mosh-server
# linked against libprotobuf.34.1.0.dylib, which protobuf 35 removed). A presence
# check keeps the broken item; this probe runs `otool -L`/`-l` and fails when a
# referenced dylib is absent — without executing the binary (so it is sudo-free
# and safe in the menu scanner / fast check path).
#
# Usage:
#   bash mach-o-resolvable.sh <binary>
# Exit:
#   0  every load-command path resolves, OR the file is not Mach-O / otool is
#      absent (nothing to disprove → conservative pass)
#   1  the binary is missing, OR a referenced dylib cannot be resolved on disk
#      (diagnostic on stderr)
#
# Resolution rules (dyld-faithful subset; DIRECT load commands only, no recursion):
#   - /usr/lib/* and /System/*            → present (dyld shared cache, not on disk)
#   - absolute /path                      → must exist on disk
#   - @loader_path/X, @executable_path/X  → resolved against the (symlink-resolved)
#                                           binary's directory; must exist
#   - @rpath/X                            → tried against each LC_RPATH entry (each
#                                           itself possibly @loader_path-relative)
#                                           plus the dyld default /usr/local/lib;
#                                           resolves if ANY candidate exists
#
# Conservative bias: only FAIL on a path we can concretely DISPROVE. Anything we
# cannot classify passes, so a healthy install is never falsely failed — a false
# fail here would abort the whole engine run with rc 67.
#
# bash 3.2 floor (engine runs /bin/bash on macOS); errexit intentionally OFF so a
# probe failure returns rather than aborts.

set -u

bin="${1:-}"
[[ -n "$bin" ]] || { echo "mach-o-resolvable: no binary given" >&2; exit 1; }

# No otool (no CommandLineTools/Xcode) → cannot probe; conservative pass so we
# never falsely fail an item just because the toolchain is absent.
command -v otool >/dev/null 2>&1 || {
    echo "mach-o-resolvable: otool not found — skipping probe for $bin" >&2; exit 0; }

[[ -e "$bin" ]] || { echo "mach-o-resolvable: binary missing: $bin" >&2; exit 1; }

# Follow symlinks to the final target (bounded), then resolve its physical dir.
# BSD readlink (no -f) is universal on macOS; avoids a realpath dependency.
_resolve_symlink() {
    local p="$1" i=0 link
    while [[ -L "$p" && $i -lt 40 ]]; do
        link="$(readlink "$p")"
        case "$link" in
            /*) p="$link" ;;
            *)  p="$(dirname "$p")/$link" ;;
        esac
        i=$((i+1))
    done
    printf '%s' "$p"
}
_real="$(_resolve_symlink "$bin")"
BINDIR="$(cd "$(dirname "$_real")" 2>/dev/null && pwd -P)" || BINDIR="$(dirname "$_real")"

# Substitute @loader_path / @executable_path with the binary's directory.
# (For a top-level executable both equal its own dir; we probe executables.)
_subst_at() {
    local s="$1"
    case "$s" in
        @loader_path)       printf '%s' "$BINDIR" ;;
        @loader_path/*)     printf '%s/%s' "$BINDIR" "${s#@loader_path/}" ;;
        @executable_path)   printf '%s' "$BINDIR" ;;
        @executable_path/*) printf '%s/%s' "$BINDIR" "${s#@executable_path/}" ;;
        *)                  printf '%s' "$s" ;;
    esac
}

# Collect LC_RPATH entries, each resolved through _subst_at.
RPATH_DIRS=()
while IFS= read -r rp; do
    [[ -n "$rp" ]] || continue
    RPATH_DIRS+=("$(_subst_at "$rp")")
done < <(otool -l "$bin" 2>/dev/null | awk '
    /^[ \t]*cmd LC_RPATH$/ { inrp=1; next }
    inrp && /^[ \t]*path /  {
        sub(/^[ \t]*path /, "")
        sub(/ \([^()]*\)$/, "")
        print
        inrp=0
    }
')

# Walk the direct load-command dylib paths. otool -L line 1 is the binary itself
# (and per-arch banners on fat binaries) — both end in ":" so we skip them; dep
# lines are "<tab><path> (compatibility version ...)" → trim the metadata
# suffix; the path itself may contain spaces.
missing=""
while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
        /usr/lib/*|/System/*)
            continue ;;                              # dyld shared cache
        @loader_path|@loader_path/*|@executable_path|@executable_path/*)
            r="$(_subst_at "$dep")"
            [[ -e "$r" ]] && continue
            missing="$dep  (→ $r)"; break ;;
        @rpath/*)
            suffix="${dep#@rpath/}"
            found=0
            for d in "${RPATH_DIRS[@]+"${RPATH_DIRS[@]}"}" /usr/local/lib; do
                [[ -n "$d" && -e "$d/$suffix" ]] && { found=1; break; }
            done
            [[ "$found" -eq 1 ]] && continue
            missing="$dep  (no LC_RPATH candidate resolves)"; break ;;
        @*)
            continue ;;                              # unknown @token → can't disprove
        /*)
            [[ -e "$dep" ]] && continue
            missing="$dep"; break ;;
        *)
            continue ;;                              # relative/bare → dyld default search
    esac
    done < <(otool -L "$bin" 2>/dev/null | awk '
        NR == 1 || /:$/ { next }
        {
            sub(/^[ \t]+/, "")
            sub(/ \([^()]*\)$/, "")
            print
        }
    ')

if [[ -n "$missing" ]]; then
    echo "mach-o-resolvable: $bin → unresolved load command: $missing" >&2
    exit 1
fi
exit 0
