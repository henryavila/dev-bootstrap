# dev-bootstrap

Configuração reproduzível de máquinas de desenvolvimento em WSL2/Ubuntu, macOS 26 e Windows (via WSL).

Um dos três repos de uma arquitetura em camadas:

| Repo | Papel | Visibilidade |
|------|-------|--------------|
| **dev-bootstrap** (este) | Instala ferramentas e aplica configs opinionadas globais | público |
| [dotfiles-template](https://github.com/henryavila/dotfiles-template) | Skeleton para dotfiles pessoais (`.example` files + `install.sh`) | público (marcado como template) |
| `<user>/dotfiles` | Dotfiles pessoais, derivado do template via "Use this template" | **privado** (cada dev) |

**Divisão de responsabilidades**: bootstrap instala CLI/daemon/stack e grava configs universais (bashrc, inputrc, gitconfig global, fragments em `~/.bashrc.d/`); dotfiles pessoal aplica identidade + overrides.

## Quickstart

### Windows (sem WSL)

PowerShell **como administrador**:

```powershell
git clone https://github.com/henryavila/dev-bootstrap "$env:USERPROFILE\dev-bootstrap"
cd "$env:USERPROFILE\dev-bootstrap"
.\windows\install-wsl.ps1
```

Reinicie, abra o Ubuntu recém-instalado e siga abaixo.

### WSL2/Ubuntu ou macOS

```bash
git clone https://github.com/henryavila/dev-bootstrap ~/dev-bootstrap
cd ~/dev-bootstrap

# rodar tudo (não-opt-in): 7 topics
bash bootstrap.sh

# ver plano sem executar
DRY_RUN=1 bash bootstrap.sh

# só alguns topics
ONLY_TOPICS="00-core 10-languages" bash bootstrap.sh

# ativar Laravel + remote access
INCLUDE_LARAVEL=1 INCLUDE_REMOTE=1 bash bootstrap.sh

# aplicar também dotfiles pessoais no fim
DOTFILES_REPO=git@github.com:you/dotfiles.git bash bootstrap.sh
```

Na primeira linha do bootstrap roda `sudo -v` (warmup do cache — prompta senha 1x, os topics subsequentes são silenciosos durante a janela de ~5–15min).

## Topics

| Topic | Instala / Aplica | Opt-in via |
|-------|------------------|------------|
| `00-core` | git, curl, build-essential, jq, unzip, envsubst (gettext) | — |
| `10-languages` | Node via fnm + LTS, PHP 8.4 (ondrej ppa / brew), Python 3 | — |
| `20-terminal-ux` | fzf, bat, eza, zoxide, ripgrep, fd, starship (com Catppuccin Mocha embutido), lazygit, delta + Nerd Font CaskaydiaCove | — |
| `30-shell` | `~/.bashrc`/`~/.zshrc` loaders + `~/.inputrc` (word-kill, completion niceties) | — |
| `40-tmux` | tmux + `~/.tmux.conf` (prefixo `Ctrl+a`) | — |
| `50-git` | gitconfig global opinionado (delta, zdiff3, aliases) + fragment `~/.bashrc.d/50-git.sh` com aliases `g`/`gs`/`gco`/… | — |
| `60-laravel-stack` | MySQL, Redis, Nginx, PHP-FPM, mkcert, catchall `*.localhost` | `INCLUDE_LARAVEL=1` |
| `70-remote-access` | sshd (com hardening via `sshd_config.d/99-${USER}.conf`), Tailscale, mosh + **drop-in systemd** que seta MTU 1200 em `tailscale0` pra prevenir SSH KEX PQ hang | `INCLUDE_REMOTE=1` |
| `80-claude-code` | Claude Code CLI + **Syncthing daemon** (P2P sync) — fundação do Claude Sync cross-machine do dotfiles | — |
| `90-editor` | wrapper `typora-wait` para usar como `$EDITOR` | `INCLUDE_EDITOR=1` |
| `95-dotfiles-personal` | clona `$DOTFILES_REPO` em `$DOTFILES_DIR` (default `~/dotfiles`) + roda `install.sh` | `DOTFILES_REPO=<url>` |

Cada topic tem um `README.md` próprio com detalhes. Fluxo internamente: `install.$OS.sh` (se existe) ou `install.sh` (fallback OS-agnóstico), depois `lib/deploy.sh` processa `templates/` quando houver. Templates `bashrc.d-<topic>.sh` / `zshrc.d-<topic>.sh` mapeam automaticamente pra `~/.bashrc.d/<topic>.sh` / `~/.zshrc.d/<topic>.sh`.

## Env vars reconhecidas

| Var | Efeito |
|-----|--------|
| `SKIP_TOPICS` | lista espaço-separada de topics a pular |
| `ONLY_TOPICS` | rodar apenas estes topics |
| `DRY_RUN=1` | imprime o que rodaria sem executar (pula `sudo -v`) |
| `DOTFILES_REPO` | URL/path do repo dotfiles pessoal (aceita `file://` para testes locais) |
| `DOTFILES_DIR` | destino do clone (default `~/dotfiles`) |
| `GIT_NAME` / `GIT_EMAIL` | identidade — aplicada só se `user.name`/`user.email` não existem (topic 50-git preserva existentes) |
| `CODE_DIR` | raiz de projetos (default `~/code/web`) |
| `INCLUDE_LARAVEL` / `INCLUDE_REMOTE` / `INCLUDE_EDITOR` | ativa topic opt-in |
| `NO_COLOR=1` | desabilita output colorido (auto se não for TTY) |

## Logs

Saída completa de cada execução em `/tmp/dev-bootstrap-<os>-<timestamp>.log`. O bootstrap imprime o path no início.

## Estrutura

```
dev-bootstrap/
├── bootstrap.sh              # runner — detect OS, warmup sudo, roda topics
├── lib/                      # detect-os.sh, detect-brew.sh, deploy.sh, log.sh
├── topics/NN-<nome>/         # unidades idempotentes de instalação
│   ├── install.$OS.sh        # WSL ou Mac
│   ├── templates/            # arquivos deployados via lib/deploy.sh
│   ├── verify.sh             # checagem não-destrutiva
│   └── README.md             # doc por topic
├── windows/install-wsl.ps1   # bootstrap Windows → WSL2 + Nerd Font
├── docs/SPEC.md              # especificação técnica completa
└── .github/workflows/        # CI
```

## Releases

| Tag | Destaque |
|-----|---------|
| `v2026-04-19` | Enriqueceu `~/.inputrc` (word-kill, completion niceties) + novo fragment `topics/50-git/templates/bashrc.d-50-git.sh` com aliases `g`/`gs`/`gco`/`whoops`/`gmm` + `__git_complete` (bash). |
| `v2026-04-20` | Topic `80-claude-code` split em `install.wsl.sh` / `install.mac.sh`; **instala Syncthing daemon** pro Claude Sync cross-machine (folder `claude/` no dotfiles-template usa `.stignore` pra controlar o que replica). |
| `v2026-04-21` | Topic `70-remote-access` automatiza o fix Tailscale MTU via drop-in `/etc/systemd/system/tailscaled.service.d/mtu.conf` (Linux). Mac tem script `scripts/mac-tailscale-mtu-fix.sh` on-demand. |
| *(hotfixes pós-v2026-04-21)* | Fix TOML scope bug em `20-terminal-ux/templates/starship.toml`; bootstrap passou a rodar `sudo -v` warmup no início; remoção de legacy `/etc/sudoers.d/10-${USER}-nopasswd` (attack surface indesejada — `sudo -v` cache resolve). |

### Discipline de release

Mudanças estruturais (novo topic, mudança em `lib/`, `install.sh`, `bootstrap.sh`) levam:

1. Commit com **migration note** no corpo — "forks existentes que já rodaram X devem Y". Tempo estimado, arquivos afetados, comando para aplicar.
2. Tag datada: `git tag -a v2026-MM-DD -m "resumo"`.
3. `gh release create v2026-MM-DD --notes-from-tag` pós-push.

Hotfixes sem mudança estrutural (bug em template, typo em README) usam commit normal sem tag.

## CI

- `.github/workflows/lint.yml` (Tier 1) — shellcheck + `bash -n` em todo push/PR.
- `.github/workflows/integration.yml` (Tier 2, previsto em v1.1) — roda `bootstrap.sh` em matrix `ubuntu-22.04`, `ubuntu-24.04`, `macos-latest`, valida idempotência (2º run = noop) e executa `verify.sh` de cada topic.

## Dotfiles pessoais

Este repo **nunca** versiona configs pessoais (SSH, identidade git, aliases project-specific). Para isso, use [dotfiles-template](https://github.com/henryavila/dotfiles-template): clique "Use this template" no GitHub, marque o repo como **privado**, e aponte `DOTFILES_REPO=<url>` antes de rodar `bootstrap.sh`.

## Contribuir

1. Adicionar topic novo: copiar estrutura de `topics/00-core/`.
2. Idempotência obrigatória: segunda execução = no-op (`already installed`, `up to date`). CI valida.
3. Antes de abrir PR: `shellcheck topics/<topic>/*.sh` deve passar.

## Veja também

- [`docs/SPEC.md`](docs/SPEC.md) — especificação técnica (arquitetura, critérios de aceitação, roadmap).
- [`docs/ALIASES.md`](docs/ALIASES.md) — inventário dos aliases universais (shell + git) que todo dev que rodou o bootstrap recebe.
- `topics/<topic>/README.md` — customização e gotchas por topic.
- [`dotfiles-template`](https://github.com/henryavila/dotfiles-template) — o outro lado da camada: overrides pessoais.
