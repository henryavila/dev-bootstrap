# 85-code-server

Opt-in macOS topic that installs `code-server` as a standalone build under
`~/.local`, then runs it through a user LaunchAgent.

Enable it with:

```bash
INCLUDE_CODE_SERVER=1 bash bootstrap.sh
```

Useful knobs:

```bash
CODE_SERVER_VERSION=4.112.0
CODE_SERVER_PORT=8080
CODE_SERVER_LABEL=com.${USER}.code-server
CODE_SERVER_TAILSCALE_SERVE=0
```

Defaults are intentionally conservative:

- `bind-addr: 127.0.0.1:8080`
- `auth: password`
- config directory `0700`, `config.yaml` `0600`
- no GitHub token or password in the plist
- remote access through Tailscale Serve by default; set
  `CODE_SERVER_TAILSCALE_SERVE=0` to keep it local-only

GitHub auth uses the local `gh` CLI at service start. The generated wrapper
exports `GITHUB_TOKEN="$(gh auth token)"` only for the `code-server` process,
so the GitHub extensions can start authenticated without writing a token to
the repo, plist, or `config.yaml`.

Verify:

```bash
bash topics/85-code-server/verify.sh
```
