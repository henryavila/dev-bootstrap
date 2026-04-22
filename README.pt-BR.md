# dev-bootstrap

[![smoke-test](https://github.com/henryavila/dev-bootstrap/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/henryavila/dev-bootstrap/actions/workflows/smoke-test.yml)
[![lint](https://github.com/henryavila/dev-bootstrap/actions/workflows/lint.yml/badge.svg)](https://github.com/henryavila/dev-bootstrap/actions/workflows/lint.yml)

Configuração reproduzível de máquinas de desenvolvimento em WSL2/Ubuntu, macOS e Windows (via WSL).

> **Idiomas:** [English](README.md) · Português (este arquivo)

Um dos três repos de uma arquitetura em camadas:

| Repo | Papel | Visibilidade |
|------|-------|--------------|
| **dev-bootstrap** (este) | Instala ferramentas e aplica configs opinionadas globais | público |
| [dotfiles-template](https://github.com/henryavila/dotfiles-template) | Skeleton para dotfiles pessoais (`.example` files + `install.sh`) | público (GitHub template) |
| `<user>/dotfiles` | Dotfiles pessoais, derivado do template via *Use this template* | **privado** (por usuário) |

**Separação de responsabilidades:** o bootstrap instala CLI/daemons/stack e grava configs universais (bashrc, inputrc, gitconfig global, fragments em `~/.bashrc.d/`); os dotfiles pessoais aplicam identidade + overrides em cima.

## Quickstart

### Windows (antes do WSL)

PowerShell **como administrador**:

```powershell
git clone https://github.com/henryavila/dev-bootstrap "$env:USERPROFILE\dev-bootstrap"
cd "$env:USERPROFILE\dev-bootstrap"
.\windows\install-wsl.ps1
```

Reinicie, abra o Ubuntu recém-instalado e siga as instruções WSL abaixo.

### WSL2/Ubuntu ou macOS

**Modo interativo (default):**

```bash
git clone https://github.com/henryavila/dev-bootstrap ~/dev-bootstrap
cd ~/dev-bootstrap
bash bootstrap.sh
```

Ao rodar sem nenhuma env var, o bootstrap abre um menu `whiptail` que pergunta:

1. Quais topics opt-in ativar (`60-laravel-stack` / `70-remote-access` / `90-editor` / `95-dotfiles-personal` — todos pré-marcados; você desmarca o que não quer).
2. `GIT_NAME` / `GIT_EMAIL` (pula silenciosamente se `git config --global` já tiver esses valores).
3. `DOTFILES_REPO` + `DOTFILES_DIR` (só se você marcou `95-dotfiles-personal`).
4. `CODE_DIR` (só se você marcou `60-laravel-stack`).
5. Tela final com resumo e confirmação — cancelar em qualquer tela aborta limpo (sem estado parcial).

Se `whiptail` não estiver instalado, o bootstrap instala antes (`apt install whiptail` no Linux/WSL; `brew install newt` no Mac — whiptail vem dentro da formula `newt`).

**Modo automação / CI** (sem menu — env vars e flags):

```bash
# ver plano sem executar
bash bootstrap.sh --dry-run

# pular menu mesmo em TTY
NON_INTERACTIVE=1 bash bootstrap.sh
bash bootstrap.sh --non-interactive

# rodar só alguns topics
ONLY_TOPICS="00-core 10-languages" bash bootstrap.sh

# ativar topics opt-in
INCLUDE_LARAVEL=1 INCLUDE_REMOTE=1 bash bootstrap.sh

# aplicar dotfiles pessoais no fim
DOTFILES_REPO=git@github.com:you/dotfiles.git bash bootstrap.sh
```

O menu é pulado automaticamente quando: (a) `NON_INTERACTIVE=1` ou `--non-interactive`; (b) qualquer var de controle (`INCLUDE_*`, `DOTFILES_REPO`, `ONLY_TOPICS`, `CI`) já vem do env; (c) stdin/stdout não é TTY (pipe, cron, CI).

Logo após o menu (ou imediatamente, quando pulado), o bootstrap roda `sudo -v` pra warmup do cache — uma única prompt de senha, e as chamadas `sudo` subsequentes dentro da janela do cache (~5–15min) são silenciosas.

## Topics

| Topic | Instala / aplica | Opt-in |
|-------|------------------|--------|
| `00-core` | git, curl, build-essential, jq, unzip, envsubst (gettext) | — |
| `10-languages` | Node via fnm + LTS, PHP (multi-version via ondrej ppa / brew; escolhido no menu), Python 3 | — |
| `20-terminal-ux` | fzf, bat, eza, zoxide, ripgrep, fd, starship (Catppuccin Mocha), lazygit, delta + Nerd Font CaskaydiaCove | — |
| `30-shell` | loaders `~/.bashrc` / `~/.zshrc` + `~/.inputrc` (word-kill, completion niceties) | — |
| `40-tmux` | tmux + `~/.tmux.conf` (prefixo `Ctrl+a`) | — |
| `50-git` | gitconfig global opinionado (delta, zdiff3, aliases) + `~/.bashrc.d/50-git.sh` com aliases `g` / `gs` / `gco` / `whoops` / `gmm` + `__git_complete` | — |
| `60-laravel-stack` | **MySQL 8** (`mysql-server-8.0` WSL / `mysql@8.0` Mac), Redis, Nginx, PHP-FPM, mkcert, catchall `*.localhost` | `INCLUDE_LARAVEL=1` |
| `70-remote-access` | sshd (com hardening via `sshd_config.d/99-${USER}.conf`), Tailscale, mosh + drop-in systemd que seta MTU 1200 em `tailscale0` (prevenção do SSH KEX PQ hang) | `INCLUDE_REMOTE=1` |
| `80-claude-code` | Claude Code CLI + **Syncthing daemon** (P2P sync) — fundação do Claude Sync cross-machine via camada de dotfiles | — |
| `90-editor` | `~/.local/bin/typora-wait` — abre `.md` no Typora GUI a partir do terminal; WSL delega pra `Typora.exe` via interop (`wslpath -w`), macOS usa `open -W -a Typora` (LaunchServices) | `INCLUDE_EDITOR=1` |
| `95-dotfiles-personal` | clona `$DOTFILES_REPO` em `$DOTFILES_DIR` (default `~/dotfiles`) + roda o `install.sh` dele | `DOTFILES_REPO=<url>` |

Cada topic tem o próprio `README.md`. Fluxo interno: `install.$OS.sh` (se existe) ou `install.sh` (fallback OS-agnóstico), depois `lib/deploy.sh` processa `templates/` quando houver. Templates `bashrc.d-<topic>.sh` / `zshrc.d-<topic>.sh` mapeiam automaticamente pra `~/.bashrc.d/<topic>.sh` / `~/.zshrc.d/<topic>.sh`.

## Env vars e flags CLI

Primariamente para automação / CI — o menu interativo preenche essas vars pro uso humano. Qualquer env var pré-existente vence os defaults do menu.

| Var / flag | Efeito |
|------------|--------|
| `--non-interactive` / `NON_INTERACTIVE=1` | Pula menu mesmo em TTY |
| `--dry-run` / `DRY_RUN=1` | Imprime o que rodaria sem executar (também pula `sudo -v`) |
| `--help` / `-h` | Mensagem de uso |
| `SKIP_TOPICS` | lista espaço-separada de topics a pular |
| `ONLY_TOPICS` | rodar apenas estes topics |
| `DOTFILES_REPO` | URL/path do repo dotfiles pessoal (aceita `file://` para testes locais) |
| `DOTFILES_DIR` | destino do clone (default `~/dotfiles`) |
| `GIT_NAME` / `GIT_EMAIL` | identidade — aplicada só se `user.name` / `user.email` ainda não existem (topic 50-git preserva existentes) |
| `CODE_DIR` | raiz de projetos (default `~/code/web`) |
| `INCLUDE_LARAVEL` / `INCLUDE_REMOTE` / `INCLUDE_EDITOR` | ativa topic opt-in |
| `NO_COLOR=1` | desabilita output colorido (auto se não for TTY) |

## Notas sobre MySQL 8

- **WSL**: instala `mysql-server-8.0` explicitamente — não o meta `mysql-server`, que pode resolver pra MariaDB em alguns derivados do Debian.
- **Mac**: formula `mysql@8.0` do brew (a formula `mysql` default acompanha 9.x). Como `mysql@8.0` é keg-only, o installer roda `brew link --force --overwrite mysql@8.0` pra colocar `mysql` / `mysqladmin` / `mysqldump` no `$PATH`.
- **Escape hatch no Mac**: se `brew install mysql@8.0` falhar por qualquer razão, instale via [instalador DMG da Oracle](https://dev.mysql.com/downloads/mysql/) (os binários vão pra `/usr/local/mysql`). O bootstrap detecta esse path e pula o brew automaticamente.

## Logs

Saída completa de cada execução vai pra `/tmp/dev-bootstrap-<os>-<timestamp>.log`. O bootstrap imprime o path no início.

## Estrutura do projeto

```
dev-bootstrap/
├── bootstrap.sh              # runner — detecção de OS, menu interativo, sudo warmup, orquestra topics
├── lib/                      # detect-os.sh, detect-brew.sh, deploy.sh, log.sh, menu.sh
├── topics/NN-<nome>/         # unidades idempotentes de instalação
│   ├── install.$OS.sh        # WSL ou Mac
│   ├── templates/            # arquivos deployados via lib/deploy.sh
│   ├── verify.sh             # checagem não-destrutiva
│   └── README.md             # doc por topic
├── windows/install-wsl.ps1   # bootstrap Windows → WSL2 + Nerd Font
├── docs/SPEC.md              # especificação técnica
└── .github/workflows/        # CI
```

## Releases

| Tag | Destaques |
|-----|-----------|
| `v2026-04-19` | Enriqueceu `~/.inputrc` (word-kill, completion niceties) + novo `topics/50-git/templates/bashrc.d-50-git.sh` com aliases `g`/`gs`/`gco`/`whoops`/`gmm` + `__git_complete` (bash). |
| `v2026-04-20` | Topic `80-claude-code` split em `install.wsl.sh` / `install.mac.sh`; **instala Syncthing daemon** pro Claude Sync cross-machine (folder `claude/` no dotfiles-template usa `.stignore` pra controlar o que replica). |
| `v2026-04-21` | Topic `70-remote-access` automatiza o fix Tailscale MTU via drop-in `/etc/systemd/system/tailscaled.service.d/mtu.conf` (Linux). Mac tem `scripts/mac-tailscale-mtu-fix.sh` on-demand. Hotfixes: fix TOML scope do starship, `sudo -v` warmup no início do bootstrap, remoção de legacy `/etc/sudoers.d/10-${USER}-nopasswd`. |
| `v2026-04-22` | **Menu interativo whiptail vira o novo default** (seleção de topics opt-in + git identity + paths); flags CLI `--non-interactive` e `--dry-run`. MySQL 8 pinado explicitamente (`mysql-server-8.0` WSL / `mysql@8.0` Mac) com escape hatch DMG Oracle. Topic `90-editor` repositioned: `typora-wait` faz interop WSL→Windows Typora via `wslpath -w` e usa `open -W -a Typora` no macOS (discovery via LaunchServices). |

### Disciplina de release

Mudanças estruturais (novo topic, mudança em `lib/`, `install.sh`, `bootstrap.sh`) passam por:

1. Commit com **migration note** no corpo — *forks existentes que já rodaram X devem Y*. Tempo estimado, arquivos afetados, comando para aplicar.
2. Tag datada: `git tag -a v2026-MM-DD -m "resumo"`.
3. `gh release create v2026-MM-DD --notes-from-tag` pós-push.

Hotfixes sem mudança estrutural (bug em template, typo em README) usam commit normal sem tag.

## CI

- `.github/workflows/lint.yml` (Tier 1) — shellcheck + `bash -n` em todo push/PR.
- `.github/workflows/integration.yml` (Tier 2, previsto em v1.1) — roda `bootstrap.sh` em matrix `ubuntu-22.04`, `ubuntu-24.04`, `macos-latest`, valida idempotência (2º run = noop) e executa `verify.sh` de cada topic.

## Dotfiles pessoais

Este repo **nunca** versiona configs pessoais (SSH, identidade git, aliases project-specific). Para isso, use [dotfiles-template](https://github.com/henryavila/dotfiles-template): clique *Use this template* no GitHub, marque o repo novo como **privado**, e deixe o menu interativo coletar `DOTFILES_REPO` ou seta via env var antes de rodar `bootstrap.sh`.

## Contribuir

1. Adicionar topic novo: copiar a estrutura de `topics/00-core/`.
2. Idempotência obrigatória: segunda execução = no-op (`already installed`, `up to date`). CI valida.
3. Antes de abrir PR: `shellcheck topics/<topic>/*.sh` deve passar.

## Veja também

- [`docs/SPEC.md`](docs/SPEC.md) — especificação técnica (arquitetura, critérios de aceitação, roadmap).
- [`docs/ALIASES.md`](docs/ALIASES.md) — inventário dos aliases universais (shell + git) que todo dev que rodou o bootstrap recebe.
- `topics/<topic>/README.md` — customização e gotchas por topic.
- [`dotfiles-template`](https://github.com/henryavila/dotfiles-template) — o outro lado da camada: overrides pessoais.
