# 85-code-server

Opt-in macOS topic that installs `code-server` as a standalone build under
`~/.local`, then runs it through a user LaunchAgent.

Enable it with:

```bash
INCLUDE_CODE_SERVER=1 bash setup.sh
```

Useful knobs:

```bash
CODE_SERVER_VERSION=4.112.0
CODE_SERVER_UPGRADE=1
CODE_SERVER_CHECK_UPDATES=0
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

Re-running the topic does not upgrade an existing standalone binary by
surprise. It checks the latest upstream release by default and, when a newer
version exists, adds a final follow-up with the version and an explicit command
to upgrade. To upgrade intentionally:

```bash
INCLUDE_CODE_SERVER=1 CODE_SERVER_UPGRADE=1 ONLY_TOPICS=85 bash setup.sh --non-interactive
```

Pin a specific release with `CODE_SERVER_VERSION=X.Y.Z` on the same command.
Set `CODE_SERVER_CHECK_UPDATES=0` to skip the release check.

If you miss the generated password in the final install summary, read it on the
host from:

```bash
~/.config/code-server/config.yaml
```

The topic writes that file as mode `0600`. If the config was later changed to
`hashed-password`, the plaintext cannot be recovered; rerun the topic with
`CODE_SERVER_REWRITE_CONFIG=1` to set a new password.

GitHub auth uses the local `gh` CLI at service start. The generated wrapper
exports `GITHUB_TOKEN="$(gh auth token)"` only for the `code-server` process,
so the GitHub extensions can start authenticated without writing a token to
the repo, plist, or `config.yaml`.

Verify:

```bash
bash topics/85-code-server/verify.sh
```
