# dev-bootstrap

Configuração reproduzível de máquinas de desenvolvimento (WSL2/Ubuntu, macOS, Windows via WSL).

Arquitetura **topic-based**: cada pasta em `topics/NN-<nome>/` é uma unidade independente com `install.<os>.sh`, templates e `verify.sh`. O runner `bootstrap.sh` descobre e executa topics em ordem alfabética, permitindo skip/only/dry-run via env vars.

## Quickstart

### Máquina Windows (sem WSL ainda)

Abra PowerShell **como administrador** e rode:

```powershell
git clone https://github.com/henryavila/dev-bootstrap "$env:USERPROFILE\dev-bootstrap"
cd "$env:USERPROFILE\dev-bootstrap"
.\windows\install-wsl.ps1
```

Depois reinicie o Windows, abra o Ubuntu recém-instalado e siga o passo seguinte.

### WSL2/Ubuntu ou macOS

```bash
git clone https://github.com/henryavila/dev-bootstrap ~/dev-bootstrap
cd ~/dev-bootstrap

# rodar tudo
bash bootstrap.sh

# ver o que rodaria sem executar
DRY_RUN=1 bash bootstrap.sh

# rodar só alguns topics
ONLY_TOPICS="00-core 10-languages" bash bootstrap.sh

# ativar stack Laravel + remote access
INCLUDE_LARAVEL=1 INCLUDE_REMOTE=1 bash bootstrap.sh

# aplicar também os dotfiles pessoais no fim
DOTFILES_REPO=git@github.com:me/dotfiles.git bash bootstrap.sh
```

## Topics

| Topic | Propósito | Opt-in |
|-------|-----------|--------|
| `00-core` | git, curl, build-essential, envsubst | — |
| `10-languages` | Node (fnm), PHP 8.4, Composer, Python | — |
| `20-terminal-ux` | fzf, bat, eza, zoxide, starship, lazygit, delta, Nerd Font | — |
| `30-shell` | loader `~/.bashrc.d/*.sh` e `~/.zshrc.d/*.sh` | — |
| `40-tmux` | tmux + `~/.tmux.conf` (prefixo Ctrl+a) | — |
| `50-git` | gitconfig opinionado (delta, zdiff3, aliases) | — |
| `60-laravel-stack` | MySQL, Redis, Nginx, PHP-FPM, mkcert + catchall `*.localhost` | `INCLUDE_LARAVEL=1` |
| `70-remote-access` | sshd, Tailscale, mosh, sudoers NOPASSWD | `INCLUDE_REMOTE=1` |
| `80-claude-code` | Claude Code CLI | — |
| `90-editor` | wrapper `typora-wait` para usar como `$EDITOR` | `INCLUDE_EDITOR=1` |
| `95-dotfiles-personal` | clona e aplica dotfiles pessoais | `DOTFILES_REPO=<url>` |

Cada topic tem um `README.md` próprio com detalhes e opções de customização.

## Env vars reconhecidas

| Var | Efeito |
|-----|--------|
| `SKIP_TOPICS` | Lista (espaço-separada) de topics a pular |
| `ONLY_TOPICS` | Rodar apenas estes topics |
| `DRY_RUN=1` | Imprime o que rodaria sem executar |
| `DOTFILES_REPO` | URL do repo dotfiles pessoal |
| `DOTFILES_DIR` | Destino do clone (default `~/dotfiles`) |
| `GIT_NAME`, `GIT_EMAIL` | Identidade — aplicada só se `user.name`/`user.email` não existem |
| `CODE_DIR` | Raiz de projetos (default `~/code/web`) |
| `INCLUDE_LARAVEL` | Ativa `60-laravel-stack` |
| `INCLUDE_REMOTE` | Ativa `70-remote-access` |
| `INCLUDE_EDITOR` | Ativa `90-editor` |
| `NO_COLOR=1` | Desabilita output colorido |

## Logs

Saída completa de cada execução vai para `/tmp/dev-bootstrap-<os>-<timestamp>.log`.

## Estrutura

```
dev-bootstrap/
├── bootstrap.sh              # runner
├── lib/                      # detect-os, detect-brew, deploy, log
├── topics/                   # NN-<nome>/ — unidades de instalação
├── windows/install-wsl.ps1   # bootstrap de WSL2 + Nerd Font
├── docs/SPEC.md              # especificação técnica
└── .github/workflows/        # CI (lint + integração)
```

## Dotfiles pessoais

Este repo **nunca** versiona configs pessoais (SSH, identidade git, aliases de dev). Para isso, use o template [dotfiles-template](https://github.com/henryavila/dotfiles-template): clique "Use this template" no GitHub, marque o repo como **privado**, e aponte `DOTFILES_REPO=<url>` antes de rodar `bootstrap.sh`.

## CI

- **lint.yml** — shellcheck + `bash -n` em todo push/PR.
- **integration.yml** — roda `bootstrap.sh` com topics seguros em ubuntu-22.04, ubuntu-24.04 e macos-latest, valida idempotência (roda 2x) e executa `verify.sh` de cada topic.

## Contribuindo

1. Adicionar um topic novo: copiar a estrutura de `topics/00-core/` (install.$OS.sh + verify.sh + README.md).
2. Idempotência é obrigatória: segunda execução deve ser no-op.
3. Shellcheck deve passar (`bash -n` + `shellcheck topics/<topic>/*.sh`).

## Veja também

- [`docs/SPEC.md`](docs/SPEC.md) — especificação completa com critérios de aceitação e roadmap.
- `topics/<topic>/README.md` — customização por topic.
