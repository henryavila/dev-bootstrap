# shellcheck shell=bash
# scripts/lib/github-api.sh — authenticated, retrying GitHub API access.
#
# Many installers resolve "latest release" via the GitHub REST API. Anonymous
# calls are capped at 60/hour per IP; on shared CI runners that ceiling is
# routinely already exhausted, so a fresh bootstrap resolving a dozen tools in a
# row gets HTTP 429 and the whole run fails (this is what broke the smoke test).
# When a token is present (CI's GITHUB_TOKEN, or a user's GH_TOKEN) we
# authenticate — raising the limit to 5000/hour; otherwise we fall back to
# anonymous access with retry/backoff. Sourced by installers via:
#   . "${MESH_WORKSTATION_DIR:-$HOME/mesh-workstation}/scripts/lib/github-api.sh"

# gh_api_curl <url> — GET a GitHub API URL to stdout. Adds a bearer token when
# GITHUB_TOKEN / GH_TOKEN is set. Retries up to 4 times with linear backoff on
# any curl/HTTP failure (notably 429). Returns curl's exit code on final fail.
gh_api_curl() {
    local url="$1" token="${GITHUB_TOKEN:-${GH_TOKEN:-}}" attempt rc
    # Callers may tighten the budget (e.g. rust-bins soft_fail path) via
    # MESH_GH_API_ATTEMPTS. Default remains 4 for anonymous 429 backoff.
    local max_attempts="${MESH_GH_API_ATTEMPTS:-4}"
    [[ "$max_attempts" -ge 1 ]] || max_attempts=1
    if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
        token="$(gh auth token 2>/dev/null)" || token=""
    fi
    local -a hdrs=(-H "Accept: application/vnd.github+json" \
                   -H "X-GitHub-Api-Version: 2022-11-28")
    [[ -n "$token" ]] && hdrs+=(-H "Authorization: Bearer $token")
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        if curl -fsSL --connect-timeout 8 --max-time 20 "${hdrs[@]}" "$url"; then
            return 0
        fi
        rc=$?
        [[ "$attempt" -lt "$max_attempts" ]] || return "$rc"
        sleep "$((attempt * 2))"
    done
}

# gh_latest_tag <owner/repo> — echo the latest release tag_name, or return 1.
gh_latest_tag() {
    local repo="$1" tag
    tag="$(gh_api_curl "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name')" || return 1
    [[ -n "$tag" && "$tag" != "null" ]] || return 1
    printf '%s\n' "$tag"
}
