#!/usr/bin/env bash
# tests/integration/code-server-codex-compat.test.sh
#
# Regression coverage for the code-server Codex extension compatibility shim.
# openai.chatgpt@26.623.61825 reads `navigator` at module load time; VS Code
# 1.118's extension host exposes a guarded Node global that throws there.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
DRIVER="$REPO_ROOT/topics/remote-access/mac/code-server.sh"

MESH_WORKSTATION_DIR="$REPO_ROOT"
# shellcheck source=/dev/null
. "$DRIVER"

# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t code-server-codex-compat.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

NEEDLE='typeof navigator<"u"&&navigator?.userAgent?.includes("Cloudflare")'

SCRIPT="$SANDBOX/code-server-codex-compat"
ASSERT_MSG="compat script generator exists and succeeds" \
    assert_true 'write_code_server_codex_compat_script "$SCRIPT"'
ASSERT_MSG="generated compat script is executable" \
    assert_true '[[ -x "$SCRIPT" ]]'

ROOT="$SANDBOX/user-data"
EXT="$ROOT/extensions/openai.chatgpt-26.623.61825-darwin-arm64/out/extension.js"
mkdir -p "$(dirname "$EXT")"
printf 'before:%s:after\n' "$NEEDLE" > "$EXT"

ASSERT_MSG="compat script patches the problematic navigator guard" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_not_contains "$(cat "$EXT")" "$NEEDLE" \
    "patched extension no longer reads navigator during module load"
assert_contains "$(cat "$EXT")" 'before:false:after' \
    "patch replaces only the guarded Cloudflare probe"
assert_file_exists "${EXT}.bak-mesh-navigator" \
    "patch keeps a backup of the original extension bundle"
assert_contains "$(cat "${EXT}.bak-mesh-navigator")" "$NEEDLE" \
    "backup preserves the original navigator guard"

before_second_run="$(cat "$EXT")"
ASSERT_MSG="compat script is idempotent on already patched extension" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_eq "$(cat "$EXT")" "$before_second_run" \
    "second patch run leaves patched bundle unchanged"
assert_contains "$(cat "${EXT}.bak-mesh-navigator")" "$NEEDLE" \
    "second patch run does not overwrite the original backup"

ROOT="$SANDBOX/missing-extension"
mkdir -p "$ROOT"
ASSERT_MSG="compat script is a no-op when Codex extension is absent" \
    assert_true '"$SCRIPT" "$ROOT"'

ROOT="$SANDBOX/unrelated-extension"
EXT="$ROOT/extensions/openai.chatgpt-99/out/extension.js"
mkdir -p "$(dirname "$EXT")"
printf 'typeof navigator<"u"&&navigator.userAgent\n' > "$EXT"
ASSERT_MSG="compat script ignores non-matching navigator usage" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_contains "$(cat "$EXT")" 'navigator.userAgent' \
    "non-matching navigator usage remains unchanged"

ROOT="$SANDBOX/webview-preload"
INDEX="$ROOT/extensions/openai.chatgpt-26.623.61825-darwin-arm64/webview/assets/index-fixture.js"
HTML="$ROOT/extensions/openai.chatgpt-26.623.61825-darwin-arm64/webview/index.html"
mkdir -p "$(dirname "$INDEX")"
cat > "$INDEX" <<'JS'
const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["./app-main.js","./chunk-a.js","./chunk-b.css"])))=>i.map(i=>d[i]);
import{t as e}from"./preload-helper.js";await e(()=>import(`./app-main.js`),__vite__mapDeps([0,1,2]),import.meta.url);
JS
cat > "$HTML" <<'HTML'
<!doctype html><script type="module" crossorigin src="./assets/index-fixture.js"></script>
HTML

ASSERT_MSG="compat script filters Codex webview eager preload dependency list" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_contains "$(cat "$INDEX")" 'await e(()=>import(`./app-main.js`),__vite__mapDeps([2]),import.meta.url);' \
    "webview entry still imports app-main while preserving CSS preload"
assert_not_contains "$(cat "$INDEX")" '__vite__mapDeps([0,1,2])' \
    "webview entry no longer requests JS preloads"
assert_file_exists "${INDEX}.bak-mesh-preload" \
    "webview preload patch keeps a backup of the original entry bundle"
assert_contains "$(cat "${INDEX}.bak-mesh-preload")" '__vite__mapDeps([0,1,2])' \
    "webview preload backup preserves the original eager preload map"
assert_file_exists "${INDEX%.js}.mesh-preload-css.js" \
    "compat script writes a cache-busted Codex webview entry"
assert_contains "$(cat "${INDEX%.js}.mesh-preload-css.js")" 'await e(()=>import(`./app-main.js`),__vite__mapDeps([2]),import.meta.url);' \
    "cache-busted Codex entry contains the patched preload call"
assert_contains "$(cat "$HTML")" './assets/index-fixture.mesh-preload-css.js' \
    "Codex webview HTML points at the cache-busted entry"
assert_file_exists "${HTML}.bak-mesh-preload" \
    "Codex webview HTML patch keeps a backup"
assert_contains "$(cat "${HTML}.bak-mesh-preload")" './assets/index-fixture.js' \
    "Codex webview HTML backup preserves the original entry URL"

before_preload_second_run="$(cat "$INDEX")"
before_html_second_run="$(cat "$HTML")"
before_busted_second_run="$(cat "${INDEX%.js}.mesh-preload-css.js")"
ASSERT_MSG="compat script preload patch is idempotent" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_eq "$(cat "$INDEX")" "$before_preload_second_run" \
    "second preload patch run leaves webview entry unchanged"
assert_eq "$(cat "$HTML")" "$before_html_second_run" \
    "second preload patch run leaves Codex webview HTML unchanged"
assert_eq "$(cat "${INDEX%.js}.mesh-preload-css.js")" "$before_busted_second_run" \
    "second preload patch run leaves cache-busted Codex entry unchanged"

ROOT="$SANDBOX/unrelated-preload"
INDEX="$ROOT/extensions/openai.chatgpt-26.623.61825-darwin-arm64/webview/assets/index-fixture.js"
mkdir -p "$(dirname "$INDEX")"
cat > "$INDEX" <<'JS'
import{t as e}from"./preload-helper.js";await e(()=>import(`./settings.js`),__vite__mapDeps([0,1]),import.meta.url);
JS
ASSERT_MSG="compat script ignores non app-main preload calls" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_contains "$(cat "$INDEX")" '__vite__mapDeps([0,1])' \
    "non app-main preload call remains unchanged"

ROOT="$SANDBOX/claude-cache-bust"
CLAUDE_EXT="$ROOT/extensions/anthropic.claude-code-2.1.197-darwin-arm64"
mkdir -p "$CLAUDE_EXT/webview"
printf 'console.log("claude webview");\n' > "$CLAUDE_EXT/webview/index.js"
printf 'body{color:var(--vscode-foreground)}\n' > "$CLAUDE_EXT/webview/index.css"
cat > "$CLAUDE_EXT/extension.js" <<'JS'
let js=yt.Uri.joinPath(this.extensionUri,"webview","index.js");
let css=yt.Uri.joinPath(this.extensionUri,"webview","index.css");
JS

ASSERT_MSG="compat script cache-busts Claude Code webview assets" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_file_exists "$CLAUDE_EXT/webview/index.mesh-cache.js" \
    "Claude webview JS is copied to a cache-busted name"
assert_file_exists "$CLAUDE_EXT/webview/index.mesh-cache.css" \
    "Claude webview CSS is copied to a cache-busted name"
assert_contains "$(cat "$CLAUDE_EXT/extension.js")" '"webview","index.mesh-cache.js"' \
    "Claude extension loads the cache-busted JS"
assert_contains "$(cat "$CLAUDE_EXT/extension.js")" '"webview","index.mesh-cache.css"' \
    "Claude extension loads the cache-busted CSS"
assert_not_contains "$(cat "$CLAUDE_EXT/extension.js")" '"webview","index.js"' \
    "Claude extension no longer references the stable JS URL"
assert_file_exists "$CLAUDE_EXT/extension.js.bak-mesh-webview-cache" \
    "Claude extension patch keeps a backup"
assert_contains "$(cat "$CLAUDE_EXT/extension.js.bak-mesh-webview-cache")" '"webview","index.js"' \
    "Claude backup preserves the original stable webview URL"

before_claude_extension_second_run="$(cat "$CLAUDE_EXT/extension.js")"
before_claude_js_second_run="$(cat "$CLAUDE_EXT/webview/index.mesh-cache.js")"
ASSERT_MSG="compat script Claude cache-bust patch is idempotent" \
    assert_true '"$SCRIPT" "$ROOT"'
assert_eq "$(cat "$CLAUDE_EXT/extension.js")" "$before_claude_extension_second_run" \
    "second Claude cache-bust run leaves extension bundle unchanged"
assert_eq "$(cat "$CLAUDE_EXT/webview/index.mesh-cache.js")" "$before_claude_js_second_run" \
    "second Claude cache-bust run leaves copied webview JS unchanged"

summary
