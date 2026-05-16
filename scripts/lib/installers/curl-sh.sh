# Driver: curl-sh. Install via piped curl. spec is the URL.
# Caller may set YAML_BIN env var to indicate the binary name to detect.
curl_sh_check()   { command -v "${YAML_BIN:-$(basename "$1" .sh)}" >/dev/null 2>&1; }
curl_sh_install() { curl -fsSL "$1" | sh; }
