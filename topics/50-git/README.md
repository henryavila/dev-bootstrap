# 50-git

Aplica `gitconfig.keys` em `~/.gitconfig` via `git config --global`, preservando `user.*` e `credential.*` já existentes.

**Destaques:** `init.defaultBranch=main`, `core.pager=delta`, `merge.conflictstyle=zdiff3`, `push.autoSetupRemote=true`, aliases comuns (`co`, `br`, `st`, `lg`, `amend`, `undo`, …).

**Identidade:** se `user.name` e `user.email` não estão setados e `GIT_NAME` / `GIT_EMAIL` foram exportados, são aplicados. Caso contrário, preserva o que estiver no config.

**Adicionar/remover configs:** edite `templates/gitconfig.keys` e rode `ONLY_TOPICS=50-git bash bootstrap.sh`.
