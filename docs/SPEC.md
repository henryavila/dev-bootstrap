# dev-bootstrap — Especificação

**Versão:** 1.0
**Data:** 2026-04-19
**Status:** aprovado para implementação

## 1. Contexto e Propósito

### Problema

Não há processo reproduzível para configurar máquinas de desenvolvimento (pessoais ou de devs terceirados) no ecossistema de trabalho do Henry. O projeto anterior (`wsl-dev-setup`) ficou complexo (Node + Ink + React + 94KB de bash monolítico), quebrou, e cobre apenas WSL.

### Objetivo

Repo público `dev-bootstrap` que:

1. **Configura máquinas novas** em 3 ambientes: Windows (bootstrap do WSL), WSL2/Ubuntu nativo, macOS.
2. **Instala stack reproduzível**: git, Node, PHP 8.4, Python corrente, Claude Code, terminal UX moderno, tmux, Laravel stack opcional, remote access opcional.
3. **Serve dev terceirado**: ninguém precisa entender framework pesado. Bash legível, documentação clara.
4. **Integra dotfiles pessoais** (repo privado por dev) via variável de ambiente — sem misturar configs pessoais com o repo público.

### Não-objetivos

- Configuration management de múltiplas máquinas (fleet) — se escalar, considerar Ansible/Nix.
- Suporte a Windows nativo para desenvolvimento (sem WSL).
- Linux não-Ubuntu (Arch, Fedora) no MVP.
- Multi-versão de linguagens via mise (fnm só pra Node basta para o stack atual).

## 2. Arquitetura dos 3 repos

| Repo | Visibilidade | Propósito | Dono |
|------|--------------|-----------|------|
| `henryavila/dev-bootstrap` | público | Setup reproduzível de máquina (software + configs opinionated) | Henry |
| `henryavila/dotfiles-template` | público, marcado como template | Skeleton para dotfiles pessoais de qualquer dev | Henry |
| `henryavila/dotfiles` | **privado** | Dotfiles pessoais do Henry (criado a partir do template) | Henry |
| `dev-X/dotfiles` | privado de cada dev | Dotfiles pessoais do dev terceirado | Dev terceirado |

### Fluxo de uso

```
┌─────────────────────────────────────────────────────┐
│ 0. git clone https://github.com/henryavila/dev-bootstrap
│    (Windows: em %USERPROFILE%; WSL/Mac: em ~)
│ 1. Dev tem máquina Windows → windows\install-wsl.ps1 │
│ 2. Dev tem WSL/Mac → bash bootstrap.sh               │
│ 3. (opcional) Dev cria seu dotfiles a partir do     │
│    template público `dotfiles-template`              │
│ 4. DOTFILES_REPO=... bash bootstrap.sh aplica as     │
│    configs pessoais no final                         │
└─────────────────────────────────────────────────────┘
```

## 3. Padrão Topic

### Convenção

Cada **topic** é uma pasta em `topics/` com prefixo numérico (ordem de execução):

```
topics/NN-<nome>/
├── install.wsl.sh          # específico WSL/Ubuntu
├── install.mac.sh          # específico macOS
├── install.sh              # OU OS-agnóstico (fallback se não houver install.$OS.sh)
├── verify.sh               # verifica instalação correta (usado por CI)
├── templates/              # arquivos a serem deployados (opcional)
│   └── <qualquer-arquivo>
├── packages.txt            # lista apt (só WSL, opcional)
├── Brewfile                # lista brew (só Mac, opcional)
└── README.md               # propósito, dependências, customização
```

### Runner resolve `installer` assim

```bash
if [ -f "$topic/install.$OS.sh" ]; then
    installer="$topic/install.$OS.sh"
elif [ -f "$topic/install.sh" ]; then
    installer="$topic/install.sh"
else
    # topic sem install (só templates)
    skip
fi
```

### Contratos de um topic

Todo `install.*.sh` DEVE:

1. `set -euo pipefail` no topo
2. **Ser idempotente**: rodar 2x sem alterar estado (segunda execução = no-op ou skip-messages)
3. Checar pré-requisitos (`command -v X` antes de usar X) e falhar com mensagem clara se faltam
4. Logar ações em stdout: `echo "→ instalando X"`, `echo "✓ X já instalado"`
5. Não modificar arquivos fora de `$HOME` sem `sudo` explícito
6. Não mudar `cwd` permanentemente (usar subshells quando necessário)

Todo `verify.sh` DEVE:

1. Retornar exit 0 se tudo OK, exit 1 se algo faltando
2. Printar linha por item verificado: `  ✓ xxx` ou `  ✗ xxx MISSING`

## 4. Runner — `bootstrap.sh`

### Interface

```bash
bash bootstrap.sh                          # todos os topics em ordem
SKIP_TOPICS="60-laravel-stack" bash bootstrap.sh
ONLY_TOPICS="00-core 10-languages" bash bootstrap.sh
DRY_RUN=1 bash bootstrap.sh                # imprime o que rodaria sem executar
bash bootstrap.sh --help                   # lista topics + env vars
```

### Env vars reconhecidas

| Var | Efeito |
|-----|--------|
| `SKIP_TOPICS` | Lista de topics a pular (separados por espaço) |
| `ONLY_TOPICS` | Rodar apenas estes (ignora o resto) |
| `DRY_RUN=1` | Não executa, só lista |
| `DOTFILES_REPO` | URL do repo dotfiles pessoal (usado pelo topic `95-dotfiles-personal`) |
| `DOTFILES_DIR` | Diretório de destino do clone (default: `~/dotfiles`) |
| `GIT_NAME`, `GIT_EMAIL` | Identidade para `50-git` |
| `CODE_DIR` | Onde ficam os projetos (default: `~/code/web`; no Mac do Henry: `/Volumes/External/code`) |
| `INCLUDE_LARAVEL=1` | Ativa topic `60-laravel-stack` (default: skip) |
| `INCLUDE_REMOTE=1` | Ativa topic `70-remote-access` (default: skip) |
| `INCLUDE_EDITOR=1` | Ativa topic `90-editor` (default: skip) |
| `NO_COLOR=1` | Desabilita output colorido (auto se não for TTY) |

### Fluxo

```
1. OS=$(bash lib/detect-os.sh); export OS
2. se OS=mac: eval "$(bash lib/detect-brew.sh)"; export BREW_BIN BREW_PREFIX
   (se brew ainda não instalado na primeira execução, tudo bem — topic 00-core
    não depende de brew; detecção recomeça após 00-core se precisar)
3. listar topics/*/ em ordem alfabética
4. aplicar SKIP_TOPICS / ONLY_TOPICS filters
5. para topics opt-in, checar env var correspondente:
     60-laravel-stack    requer INCLUDE_LARAVEL=1    (senão skip com mensagem)
     70-remote-access    requer INCLUDE_REMOTE=1
     90-editor           requer INCLUDE_EDITOR=1
     95-dotfiles-personal requer DOTFILES_REPO setado
6. para cada topic não filtrado:
   a. se DRY_RUN: imprimir "would run: <installer>" e continuar
   b. resolve installer: prefere install.$OS.sh, fallback para install.sh
   c. bash $installer 2>&1 | tee -a $LOG   (herda $OS, $BREW_PREFIX, $CODE_DIR, $GIT_NAME, etc.)
   d. se $topic/templates/ existe: bash lib/deploy.sh $topic/templates
   e. capturar exit code; marcar falha mas continuar (não abort em erro parcial)
7. imprimir resumo (passed/failed/skipped)
8. exit 0 se tudo passou, 1 caso contrário
```

**Variáveis exportadas pelo runner** (herdadas por todos os installers e deploy.sh):
`OS`, `BREW_BIN`, `BREW_PREFIX` (se Mac), `USER`, `HOME`, `DOTFILES_REPO`, `DOTFILES_DIR`, `CODE_DIR`, `GIT_NAME`, `GIT_EMAIL`, `INCLUDE_LARAVEL`, `INCLUDE_REMOTE`, `INCLUDE_EDITOR`, `NGINX_CONF_DIR` (derivado pelo topic 60 antes do deploy), `NO_COLOR`.

### Log

`/tmp/dev-bootstrap-<os>-<timestamp>.log` com stdout+stderr de todos os topics.

## 5. `lib/` — utilitários compartilhados

### `lib/detect-os.sh`

Exporta string única na saída padrão: `wsl`, `mac`, `linux`, `unknown`.

```bash
case "$(uname -s)" in
    Darwin) echo "mac" ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
        ;;
    *) echo "unknown" ;;
esac
```

### `lib/detect-brew.sh`

Detecta o prefix do Homebrew em **qualquer localização conhecida** (evita falhas com brew em HD externo ou path customizado). Usado principalmente pelos topics macOS, mas inofensivo de rodar em WSL/Linux (exit 1 silencioso se brew ausente).

**Contrato:** escreve na stdout linhas no formato `KEY=VALUE` consumíveis por `eval`. Exit 0 se encontrou brew, 1 se não.

**Consumo pelo caller:**
```bash
if out=$(bash lib/detect-brew.sh); then
    eval "$out"    # popula BREW_BIN e BREW_PREFIX no shell atual
fi
```

**Implementação:**
```bash
# ordem de busca: PATH → padrão ARM → padrão Intel → customizado → linuxbrew
for cand in "$(command -v brew 2>/dev/null)" \
            "/opt/homebrew/bin/brew" \
            "/usr/local/bin/brew" \
            "/Volumes/External/homebrew/bin/brew" \
            "/home/linuxbrew/.linuxbrew/bin/brew"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
        echo "BREW_BIN=$cand"
        echo "BREW_PREFIX=$("$cand" --prefix)"
        exit 0
    fi
done
exit 1
```

### `lib/deploy.sh`

Recebe diretório de templates, aplica cada arquivo em destino derivado do nome. Idempotente com backup timestamped, strip CRLF, keep-5-backups. Suporta substituição de variáveis via `envsubst` quando o arquivo tem sufixo `.template`. Detecta destinos fora de `$HOME` e usa `sudo` automaticamente.

```bash
# Uso: bash lib/deploy.sh <templates-dir>
# O diretório pode conter um arquivo DEPLOY opcional definindo mappings não-convencionais.
```

Convenção de mapeamento **automática** (se nome bate, não precisa DEPLOY). **Qualquer arquivo da tabela pode ter sufixo `.template`**; o sufixo é removido no destino após envsubst.

| Nome no template (com ou sem `.template`) | Destino |
|-------------------------------------------|---------|
| `bashrc` | `~/.bashrc` |
| `zshrc` | `~/.zshrc` |
| `inputrc` | `~/.inputrc` |
| `tmux.conf` | `~/.tmux.conf` |
| `starship.toml` | `~/.config/starship.toml` |
| `bashrc.d-NN-<name>.sh` | `~/.bashrc.d/NN-<name>.sh` |
| `zshrc.d-NN-<name>.sh` | `~/.zshrc.d/NN-<name>.sh` |
| `bin/<name>` | `~/.local/bin/<name>` (executável, chmod +x) |

Exemplos: `starship.toml.template` → `~/.config/starship.toml` (com envsubst). `bin/link-project.template` → `~/.local/bin/link-project`.

### Formato do arquivo `DEPLOY` (opcional)

Para mappings fora da convenção (ex: destinos em `/etc/`, paths com substituição), o topic fornece `templates/DEPLOY`:

```
# Formato: <src-relativo-ao-templates-dir>=<destino-absoluto-ou-tildeified>
# Linhas em branco e linhas começando com # são ignoradas.
# Variáveis em ${VAR} no destino são expandidas pelo deploy.sh.
# Se src tem sufixo .template, envsubst é aplicado no CONTEÚDO antes de copiar.

sshd-snippet.template=/etc/ssh/sshd_config.d/99-${USER}.conf
nginx-catchall.conf=${NGINX_CONF_DIR}/catchall.conf
```

`lib/deploy.sh` prioriza o arquivo `DEPLOY` se existir; senão usa a convenção automática acima.

### Substituição de variáveis (`.template` suffix)

Arquivos com sufixo `.template` passam por `envsubst` durante o deploy. Variáveis do ambiente do runner (`$USER`, `$HOME`, `$BREW_PREFIX`, `$CODE_DIR`, `$NGINX_CONF_DIR`, etc.) são expandidas. O sufixo `.template` é **removido no destino** (ex: `bin/link-project.template` → `~/.local/bin/link-project`, não `~/.local/bin/link-project.template`).

### Privilégios elevados para destinos fora de `$HOME`

Quando o destino resolvido começa com `/etc/`, `/usr/local/etc/`, ou qualquer path fora de `$HOME`, `lib/deploy.sh`:

1. Pede confirmação **uma vez** no início do deploy (evita prompts repetidos)
2. Renova cache do sudo (`sudo -v`)
3. Usa `sudo cp`, `sudo mv`, `sudo chmod` para escrever o destino
4. Falha com mensagem clara se sudo for negado

Topics que escrevem em `/etc/` (ex: `70-remote-access` sshd snippet, `60-laravel-stack` nginx config) dependem dessa lógica. Nunca chamar deploy.sh num contexto não-interativo sem `sudo -n` validado.

### `lib/log.sh`

Helpers de output colorido: `info`, `ok`, `warn`, `fail`, `banner`. Carregado via `source` pelos scripts.

## 6. Os 11 topics

### `00-core`

**Propósito:** ferramentas mínimas que todo dev precisa, + dependências do próprio runner (envsubst).

**Conteúdo:**
- WSL: `git curl wget ca-certificates gnupg build-essential jq unzip gettext-base` (o último fornece `envsubst` usado por `lib/deploy.sh`)
- Mac: `git curl wget gnupg jq unzip gettext` (build-essential ≈ xcode-select, já vem; `gettext` via brew traz `envsubst` compatível)

**Templates:** nenhum.

**Nota de dependência circular:** `00-core` é o único topic que **NÃO pode** depender de `lib/deploy.sh` (que usa envsubst), já que é o topic que instala envsubst. Por isso `00-core` não tem templates.

### `10-languages`

**Propósito:** Node (via fnm), PHP 8.4 (+ extensões comuns), Composer, Python corrente.

**Conteúdo:**
- WSL: fnm (installer), Node LTS, `add-apt-repository ppa:ondrej/php`, php8.4 + ext, composer (installer oficial com checksum), python3 (apt)
- Mac: fnm (brew), Node LTS, `brew install php@8.4 composer python@3.13`

**Templates:**
- `bashrc.d-10-languages.sh` — init de fnm (`eval "$(fnm env --use-on-cd)"`), PATH para `$HOME/.composer/vendor/bin`
- `zshrc.d-10-languages.sh` — equivalente para zsh

**Env vars:** nenhuma.

### `20-terminal-ux`

**Propósito:** terminal moderno pronto out-of-the-box.

**Conteúdo:**
- WSL: `fzf bat eza zoxide ripgrep fd-find` via apt; `starship lazygit git-delta` via installer (não estão no apt default); Nerd Font via install-wsl.ps1 (Windows side)
- Mac: tudo via brew + `brew tap homebrew/cask-fonts` + `brew install --cask font-caskaydia-cove-nerd-font`

**Templates:**
- `starship.toml` com **Catppuccin Mocha** embutido (palette completa, ícones Nerd Font)
- `bashrc.d-20-terminal-ux.sh` com: `eval "$(starship init bash)"`, fzf keybindings (`Ctrl+R`, `Ctrl+T`), `eval "$(zoxide init bash)"`, aliases `ls='eza'`, `cat='bat'` (condicional)
- `zshrc.d-20-terminal-ux.sh` equivalente para zsh

### `30-shell`

**Propósito:** bashrc/zshrc modulares com loader de `~/.bashrc.d/` e `~/.zshrc.d/`.

**Conteúdo:**
- WSL: default shell = bash, mas também configura zsh se preferido
- Mac: default shell = zsh (macOS padrão)

**Templates:**
- `bashrc` — minimal: opções do shell, history, PATH base, carrega `~/.bashrc.d/*.sh`, carrega `~/.bashrc.local` no fim
- `zshrc` — equivalente para zsh, carrega `~/.zshrc.d/*.sh` e `~/.zshrc.local`
- `inputrc` — readline keybindings (Ctrl+←/→, history search)

### `40-tmux`

**Propósito:** tmux + config com prefixo Ctrl+A, mouse, splits intuitivos.

**Conteúdo:**
- WSL: `apt install tmux`
- Mac: `brew install tmux`

**Templates:**
- `tmux.conf` com: prefix C-a, mouse on, splits `|` e `-`, status bar limpo, reload config

### `50-git`

**Propósito:** gitconfig com delta como pager, merge.conflictstyle=zdiff3, init.defaultBranch=main, aliases comuns.

**Conteúdo:**
- WSL/Mac: configura via `git config --global` lendo `gitconfig.keys` (um key=value por linha)
- Preserva `[user]` e `[credential]` existentes (nunca sobrescreve email/name)

**Templates:**
- `gitconfig.keys` — 20-30 linhas com `core.pager=delta`, `delta.side-by-side=false`, aliases (`alias.co=checkout`, `alias.br=branch`, etc.)

### `60-laravel-stack` (opt-in)

**Propósito:** stack local para Laravel dev — MySQL, Redis, Nginx com catch-all `*.localhost`, PHP-FPM, mkcert.

**Ativação:** `INCLUDE_LARAVEL=1 bash bootstrap.sh`

**Conteúdo:**
- WSL: `apt install mysql-server redis-server nginx php8.4-fpm`, `curl | bash` mkcert
- Mac: `brew install mysql redis nginx mkcert` + `brew services start`

**Templates:**
- `nginx-catchall.conf.template` — deploy via `DEPLOY` file:
  - WSL: `$NGINX_CONF_DIR=/etc/nginx/sites-enabled`
  - Mac: `$NGINX_CONF_DIR=$BREW_PREFIX/etc/nginx/servers` (usa `lib/detect-brew.sh`)
- `bin/link-project.template` — script que linka `$CODE_DIR/<nome>/public` → `<nome>.localhost` (usa env var `CODE_DIR`, default `~/code/web`)

**Env vars usadas:** `CODE_DIR`, `BREW_PREFIX` (via detect-brew no Mac).

**Pós-install:** imprimir `start-services.sh` como referência.

### `70-remote-access` (opt-in)

**Propósito:** acesso remoto via SSH + Tailscale + mosh + tmux, sudoers NOPASSWD.

**Ativação:** `INCLUDE_REMOTE=1 bash bootstrap.sh`

**Conteúdo:**
- WSL: enable sshd, instala Tailscale, mosh, configura `.wslconfig` com systemd, sudoers NOPASSWD
- Mac: enable Remote Login (sshd), instala Tailscale, mosh

**Templates:**
- `sshd-snippet.template` deployado via `DEPLOY` file como `/etc/ssh/sshd_config.d/99-${USER}.conf` (hardening básico — `envsubst` expande `$USER`)

### `80-claude-code`

**Propósito:** instalar Claude Code CLI.

**Conteúdo:**
- Cross-OS: `curl -fsSL https://claude.ai/install.sh | bash` (ambos WSL e Mac)
- Validar `claude --version` após instalar

**Templates:** nenhum.

### `90-editor` (opt-in)

**Propósito:** wrapper `typora-wait` para usar Typora como `$EDITOR` (preferência do Henry, documentado em memory).

**Ativação:** `INCLUDE_EDITOR=1 bash bootstrap.sh`

**Conteúdo:** nenhum install (Typora é GUI, usuário instala separado).

**Templates:**
- `bin/typora-wait` — wrapper que espera fechar antes de retornar (usado como `EDITOR=typora-wait git commit`)

### `95-dotfiles-personal`

**Propósito:** aplicar dotfiles pessoais do dev (opt-in via env var).

**Ativação:** `DOTFILES_REPO=git@github.com:user/dotfiles.git bash bootstrap.sh`

**Conteúdo:**
1. Se `DOTFILES_REPO` não setado → skip com mensagem.
2. Senão:
   - Clona em `~/dotfiles` (ou `$DOTFILES_DIR` se setado)
   - Se `~/dotfiles/install.sh` existe: `bash ~/dotfiles/install.sh`

**Templates:** nenhum.

## 7. Shell rc fragments (`.bashrc.d/`, `.zshrc.d/`)

### Pattern

```bash
# ~/.bashrc (criado pelo topic 30-shell)
# ... opções básicas do shell ...
for f in ~/.bashrc.d/*.sh; do [ -r "$f" ] && source "$f"; done
[ -f ~/.bashrc.local ] && source ~/.bashrc.local
```

### Naming

Fragmentos em `~/.bashrc.d/` seguem prefixo numérico igual dos topics:
- `10-languages.sh` (fnm env, composer PATH)
- `20-terminal-ux.sh` (starship init, fzf keybindings, zoxide init, aliases)
- `60-laravel-stack.sh` (aliases laravel, se opt-in)

Ordem de carregamento = ordem alfabética (garante dependências).

### Nota sobre ordem vs loader

O topic `30-shell` cria os loaders `~/.bashrc` e `~/.zshrc` que iteram `~/.bashrc.d/*.sh`. Topics anteriores (`10-languages`, `20-terminal-ux`) já gravam fragments em `~/.bashrc.d/` mesmo **antes** de `30-shell` rodar.

Isso é intencional e não causa bug:
- Durante bootstrap: os installers não dependem dos fragments para funcionar (cada `install.sh` roda sem precisar do shell rc).
- Após bootstrap: `30-shell` cria o loader; user abre novo shell → tudo carrega na ordem correta.

O único caso onde faltaria carregar seria se o user rodar `source ~/.bashrc` no meio do bootstrap — recomendação é aguardar o fim e abrir novo shell.

## 8. `dotfiles-template` — especificação

### Estrutura

```
dotfiles-template/
├── README.md                    # "Use this template" workflow
├── install.sh                   # self-contained: diff + backup + symlink
├── .gitignore                   # secrets, sistema, backups
├── ssh/
│   └── config.example
├── git/
│   └── gitconfig.local.example
├── shell/
│   ├── bashrc.local.example
│   └── zshrc.local.example
└── docs/README.md
```

### Convenção `.example`

Arquivos com sufixo `.example` são placeholders comentados. O `install.sh` **pula** arquivos `.example` e processa apenas arquivos sem o sufixo. Usuário renomeia (`cp config.example config`) e customiza.

### `install.sh` do template

Self-contained (NÃO depende de `lib/deploy.sh` do `dev-bootstrap`). Duplica ~40 linhas de lógica de deploy. Motivo: template deve funcionar standalone.

Comportamento:
- Para cada arquivo não-`.example` em `ssh/`, `git/`, `shell/`:
  - Calcula destino (`ssh/config` → `~/.ssh/config`)
  - Se diff: backup + symlink
  - Se igual: skip

### Marcação template no GitHub

Após push inicial: `gh repo edit henryavila/dotfiles-template --template` (ou via UI → Settings → check "Template repository").

## 9. CI/CD

### Workflows

**`.github/workflows/lint.yml` — Tier 1 (todo push)**

```yaml
on: [push, pull_request]
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          ignore_paths: docs windows
      - name: bash syntax
        run: find topics lib -name "*.sh" -exec bash -n {} \;
```

**`.github/workflows/integration.yml` — Tier 2 (PRs para main)**

```yaml
on:
  pull_request:
    branches: [main]
jobs:
  test-wsl:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-22.04, ubuntu-24.04]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: bootstrap (safe topics)
        run: |
          ONLY_TOPICS="00-core 10-languages 20-terminal-ux 30-shell 40-tmux 50-git 80-claude-code" \
            bash bootstrap.sh
      - name: idempotency check (2nd run)
        run: |
          ONLY_TOPICS="00-core 10-languages 20-terminal-ux 30-shell 40-tmux 50-git 80-claude-code" \
            bash bootstrap.sh
      - name: verify
        run: for t in topics/{00-core,10-languages,20-terminal-ux,30-shell,40-tmux,50-git,80-claude-code}; do
               [ -x "$t/verify.sh" ] && bash "$t/verify.sh"; done

  test-mac:
    runs-on: macos-latest    # macOS 26 quando disponível
    steps:
      - uses: actions/checkout@v4
      - name: bootstrap
        run: |
          ONLY_TOPICS="00-core 10-languages 20-terminal-ux 30-shell 40-tmux 50-git 80-claude-code" \
            bash bootstrap.sh
      - name: idempotency check
        run: |
          ONLY_TOPICS="00-core 10-languages 20-terminal-ux 30-shell 40-tmux 50-git 80-claude-code" \
            bash bootstrap.sh
      - name: verify
        run: for t in topics/{00-core,10-languages,20-terminal-ux,30-shell,40-tmux,50-git,80-claude-code}; do
               [ -x "$t/verify.sh" ] && bash "$t/verify.sh"; done
```

**Tier 3 (daily E2E):** desabilitado inicialmente. Ativar quando estabilizar — agendar `cron: '0 6 * * *'` com cobertura de `60-laravel-stack` e `70-remote-access`.

### Custos estimados

- Tier 1: ~30s por push. Gratuito em repo público.
- Tier 2: ~15-25min wall-clock por PR (3 jobs paralelos). Gratuito em repo público.
- Tier 3: ~30-45min por run. Ativar depois que Tier 2 estabilizar.

## 10. Convenções de código

### Bash

- Shebang: `#!/usr/bin/env bash`
- Prólogo: `set -euo pipefail`
- Aspas duplas em todas as expansões: `"$var"`, nunca `$var`
- Arrays para listas: `local pkgs=(a b c); "${pkgs[@]}"`
- `[[ ]]` para condicionais (não `[ ]`)
- Funções: snake_case, locais: `local x="..."`
- Indentação: 4 espaços (não tab)

### Output

- `→` para ação em andamento
- `✓` para sucesso
- `!` para aviso
- `✗` para erro
- Cores via ANSI em `lib/log.sh`; desabilitar se `NO_COLOR=1` ou não for TTY

### Idempotência

Antes de instalar qualquer coisa:

```bash
if command -v X >/dev/null 2>&1; then
    echo "✓ X já instalado"
    return 0
fi
```

Antes de modificar arquivo:

```bash
if grep -qF 'LINHA_DE_MARCA' "$file"; then
    echo "✓ $file já configurado"
    return 0
fi
```

## 11. Error handling

- Falha em 1 topic **não aborta** `bootstrap.sh` — continua nos demais
- Resumo final lista falhas
- Exit code final: 0 se tudo OK, 1 se qualquer falhou
- `run_cmd()` helper para sudo com retry: se `sudo` falha por timeout, tenta de novo uma vez após renovar cache (`sudo -v`)

## 12. Critérios de aceitação

MVP aceito quando:

- [ ] `dev-bootstrap` contém 11 topics + `bootstrap.sh` + `lib/` + README
- [ ] `dotfiles-template` contém skeleton funcional + `install.sh` self-contained + marcado como template no GitHub
- [ ] `henryavila/dotfiles` privado criado a partir do template, contendo o `ssh/config` atual migrado
- [ ] Rodar `bash bootstrap.sh` no WSL atual (já configurado) retorna "todos os topics skipados" ou resultado equivalente (idempotência)
- [ ] CI Tier 1 (lint) passa em ambos os repos
- [ ] CI Tier 2 (integration) passa em ubuntu-22.04, ubuntu-24.04, macos-latest
- [ ] README explica fluxo completo (Windows → WSL → bootstrap → dotfiles-template → dotfiles)
- [ ] `wsl-dev-setup` antigo arquivado no GitHub com aviso de deprecation

## 13. Fora do escopo (desta versão)

- Suporte Linux não-Ubuntu (Arch, Fedora, Debian)
- Windows nativo como ambiente de dev (só bootstrap do WSL)
- mise/asdf (fnm é suficiente para stack atual)
- Ansible/Nix
- CI Tier 3 end-to-end (planejado para v1.1)
- Roles/perfis por tipo de dev (ex: "frontend-only" vs "fullstack") — todos os dev são fullstack por default
- Auto-update do dev-bootstrap (`dev-bootstrap update` command)
- Múltiplas versões de PHP ou Node simultâneas (fnm resolve Node; PHP fica em 8.4 fixo)

## 14. Roadmap pós-MVP

**v1.1 (backlog, sem compromisso):**
- CI Tier 3 (daily E2E com `60-laravel-stack` + `70-remote-access`)
- Topic `45-docker` (Docker Desktop ou Docker Engine dentro do WSL)
- Command `dev-bootstrap update` — pull + re-run bootstrap
- Detector de mudança no `~/.zshrc` local vs template (warn antes de sobrescrever)

**v1.2:**
- Suporte a Linux nativo (não-WSL)
- Perfis opcionais (`--profile minimal`, `--profile laravel`, `--profile devops`)
- Migração de fnm para mise se stack crescer

## 15. Referências

- wsl-dev-setup original: https://github.com/henryavila/wsl-dev-setup (a ser arquivado)
- Padrão topic-based: inspirado em `holman/dotfiles`
- Padrão `.d/` folders: systemd, `/etc/profile.d/`, oh-my-zsh plugins
- deploy.sh idempotente com diff/backup: adaptado do `deploy-dotfiles.sh` do wsl-dev-setup

## 16. Aprovação

- [x] Arquitetura topic-based (vs 3-layer / single-script / chezmoi)
- [x] Nerd Font auto-install
- [x] Catppuccin Mocha embutido no starship.toml
- [x] fnm para Node (não mise)
- [x] PHP 8.4 via ondrej/brew
- [x] CI Tier 1 + Tier 2 ativos desde MVP
- [x] CI Tier 3 adiado para após estabilização
- [x] Matrix: ubuntu-22.04, ubuntu-24.04, macos-latest
- [x] Ansible descartado
- [x] `dotfiles-template` público, marcado como template
- [x] `dotfiles` pessoal privado, criado a partir do template
- [x] Arquivar `wsl-dev-setup` antigo

**Pronto para implementação.**
