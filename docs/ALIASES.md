# ALIASES — universais (instalados pelo dev-bootstrap)

Lista compacta dos aliases que **todo dev que rodou o `bootstrap.sh`** recebe, independente de dotfiles pessoais. Dotfiles pessoais podem adicionar ou sobrescrever; pra inventário consolidado incluindo pessoais, veja o `docs/ALIASES.md` do repo dotfiles do dev.

## Fontes no repo

| Arquivo | Conteúdo |
|---------|----------|
| `topics/20-terminal-ux/templates/bashrc.d-20-terminal-ux.sh` | aliases de listagem e visualização (ls/cat/fd…) |
| `topics/50-git/templates/bashrc.d-50-git.sh` | aliases shell-level do git (g/gs/gco…) |
| `topics/50-git/data/gitconfig.keys` | aliases git-level (`git co`, `git st`) |

Os dois primeiros são deployados pelo `lib/deploy.sh` do bootstrap em `~/.bashrc.d/NN-<topic>.sh` (e zshrc equivalente). O terceiro é aplicado via `git config --global alias.X Y` no `install.sh` do topic 50-git.

## Listagem / visualização (topic 20-terminal-ux)

| Alias | Expande para | Guard |
|-------|--------------|-------|
| `ls` | `eza` | `command -v eza` |
| `ll` | `eza -l --git` | `command -v eza` |
| `la` | `eza -la --git` | `command -v eza` |
| `tree` | `eza --tree` | `command -v eza` |
| `cat` | `bat --style=plain --paging=never` | `command -v bat` |
| `bat` | `batcat` | `command -v batcat && ! bat` (Ubuntu) |
| `cat` (fallback Ubuntu) | `batcat --style=plain --paging=never` | idem |
| `fd` | `fdfind` | `command -v fdfind && ! fd` (Ubuntu) |

Tudo protegido por `command -v` — se a ferramenta não instalou, alias não é declarado (fallback ao comando nativo).

## Git shell-level (topic 50-git)

### Básicos

| Alias | Expande para |
|-------|--------------|
| `g` | `git` |
| `gs` | `git status` |
| `gl` | `git log --oneline --graph --decorate -15` |
| `gd` | `git diff` |
| `gds` | `git diff --staged` |
| `gco` | `git checkout` |
| `gb` | `git branch` |
| `gp` | `git pull` |
| `gaa` | `git add .` |
| `gc` | `git commit` |
| `grb` | `git rebase -i` |
| `gsh` | `git show` |
| `glog` | `git log --oneline --decorate --graph` |
| `gloga` | `git log --oneline --decorate --graph --all` |

### Utilitários

| Alias | Expande para | Nota |
|-------|--------------|------|
| `whoops` | `git reset --hard && git clean -df` | ⚠️ destrutivo — descarta working tree + untracked |
| `gmm` | switch main + pull + back + merge main | puxa main pra branch atual preservando o lugar |

### Autocompletar (bash-only)

O fragment também chama `__git_complete` para `g`, `gco`, `gb`, `gp`, `gd` — Tab autocompleta branches como se fosse `git`. Requer `bash-completion` (instalado pelo 20-terminal-ux).

Zsh não usa `__git_complete` — compinit padrão já resolve completion em aliases, e não queremos fragility. Documentado no próprio `zshrc.d-50-git.sh`.

## Git git-level (topic 50-git, via gitconfig global)

Aplicados via `git config --global alias.X Y`. Funcionam **dentro** do `git` (scripts, hooks, outros comandos).

| Uso | Expande para |
|-----|--------------|
| `git co` | `checkout` |
| `git br` | `branch` |
| `git st` | `status` |
| `git ci` | `commit` |
| `git sw` | `switch` |
| `git last` | `log -1 HEAD` |
| `git unstage` | `reset HEAD --` |
| `git lg` | `log --oneline --graph --decorate --all` |
| `git amend` | `commit --amend --no-edit` |
| `git undo` | `reset HEAD~1 --mixed` |
| `git df` | `diff` |
| `git dfc` | `diff --cached` |

## Como adicionar um alias universal novo

1. Decide escopo: listagem/view → 20-terminal-ux; git → 50-git; outra categoria → criar topic novo ou argumentar no PR.
2. Edita o `bashrc.d-<topic>.sh` **e** o `zshrc.d-<topic>.sh` do topic (mantém paridade).
3. Atualiza este `docs/ALIASES.md` com a linha nova.
4. Commit com migration note + tag datada.

Versões do dev-bootstrap que introduziram mudanças notáveis em aliases:

- `v2026-04-19` — criação do fragment 50-git com 16 aliases shell-level + `__git_complete`.

## Relacionado

- `topics/20-terminal-ux/README.md` — ferramentas CLI modernas.
- `topics/50-git/README.md` — aliases e defaults do git.
- Dotfiles pessoais de cada dev — adicionam aliases específicos em `~/.bashrc.d/99-personal-aliases.sh` (sobrepõem os deste repo por prefixo 99-).
