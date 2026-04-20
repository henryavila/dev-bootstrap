# 50-git

Aplica `gitconfig.keys` em `~/.gitconfig` via `git config --global`, preservando `user.*` e `credential.*` já existentes. **Desde v2026-04-19** também instala fragment de shell com aliases git curtos.

## O que é deployado

### 1. `git config --global` (via `install.sh`)

Aplica `data/gitconfig.keys` — cada linha vira `git config --global <key> <value>`. Destaques:

- `init.defaultBranch=main`, `core.pager=delta`, `merge.conflictstyle=zdiff3`
- `push.autoSetupRemote=true`, `fetch.prune=true`, `rebase.autoStash=true`
- `include.path=~/.gitconfig.local` — permite que dotfiles pessoais sobrescrevam sem mexer no config principal
- Aliases dentro do git: `co`, `br`, `st`, `ci`, `sw`, `lg`, `amend`, `undo`, `last`, `unstage`, `df`, `dfc`

### 2. Shell fragment (via `templates/` + `lib/deploy.sh`)

- `bashrc.d-50-git.sh` → `~/.bashrc.d/50-git.sh`
- `zshrc.d-50-git.sh` → `~/.zshrc.d/50-git.sh`

Aliases de shell (curtos, para o prompt, não confundir com os `git config alias.*` acima):

- `g`, `gs`, `gl`, `gd`, `gds`, `gco`, `gb`, `gp`, `gaa`, `gc`, `grb`, `gsh`, `glog`, `gloga`
- `whoops` — reset hard + clean -df (destrutivo)
- `gmm` — merge main into current branch

Bash ainda recebe `__git_complete g|gco|gb|gp|gd` para autocompletar os aliases como se fossem o próprio git.

## Identidade

Se `user.name` / `user.email` não estão setados e `GIT_NAME` / `GIT_EMAIL` foram exportados, são aplicados. Caso contrário, preserva o que estiver no config. Em fluxo normal, identidade vai no dotfiles pessoal via `~/.gitconfig.local`.

## Adicionar/remover configs

- **Git config global:** edite `data/gitconfig.keys` e rode `ONLY_TOPICS=50-git bash bootstrap.sh`.
- **Aliases shell:** edite `templates/bashrc.d-50-git.sh` (e o zsh equivalente), rode o bootstrap. Para sobrescrever localmente sem editar o bootstrap, use `~/.bashrc.d/99-personal-aliases.sh` no seu dotfiles pessoal (carregado depois).
