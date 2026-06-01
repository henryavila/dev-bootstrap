# mesh setup wizard — design brief (blink TUI)

> **Para:** Claude Design. **Objetivo:** desenhar as telas do wizard de setup do `mesh`.
> Este doc traz **só** o que a tela precisa: constraints visuais/de interação + os
> **dados reais** que viram as linhas. Implementação de engine, install scripts e schema
> ficam fora (não afetam o desenho).

---

## 0 · O que é

TUI de terminal (Ink + React + TypeScript) que roda em `bash setup.sh`. O dev escolhe
quais ferramentas instalar/remover, ajusta parâmetros, confirma, aplica. Construído sobre
o design system **blink** (Catppuccin Mocha, Nerd Font dual-mode). Componentes blink
disponíveis: `Pane`, `List`/`ListRow`, `Footer`, `Input`, `Dialog`, `Spinner`, `Cursor`.

São **4 telas**: TopicPicker → OptionsForm → SummaryConfirm → ApplyProgress.

---

## 1 · Constraints globais

| constraint | valor |
|---|---|
| **Tamanho-alvo** | 100 × 30 (cols × rows) |
| **Fallback obrigatório** | 60 × 20 (mobile via mosh) — layout não pode quebrar/cortar |
| **Tema** | Catppuccin Mocha. Accent = lavender `#b4befe` (marca blink). |
| **Idioma** | **EN** em toda a UI (labels, descs, hints, botões). |
| **Glyphs** | dual-mode: cada ícone tem `{nerd, unicode, ascii}`. Layout idêntico nos 3 sets. |
| **Input** | só teclado (sem mouse). Footer de hotkeys sempre visível. |
| **Cor não é único sinal** | estado precisa ser legível por glyph+texto também (acessibilidade / ascii). |

### Estados de uma linha de bundle (badge + cor)

| estado | quando | nerd | unicode | ascii | cor |
|---|---|---|---|---|---|
| **installed** (keep) | instalado + selecionado | `` | `✓` | `[x]` | green |
| **available** | não instalado + não selecionado | `` | `○` | `[ ]` | overlay/dim |
| **will install** | selecionado + não instalado | `` | `+` | `[+]` | lavender |
| **will remove** | instalado + desselecionado | `` | `✗` | `[-]` | red |
| **required (locked)** | bundle `required` — não-desmarcável | `` | `◆` | `(*)` | yellow |
| **has options** (sufixo) | bundle tem parâmetros p/ configurar | `` | `▸` | `>` | mauve |

---

## 2 · Tela 1 — TopicPicker (principal, 3-pane)

A tela onde o dev passa 90% do tempo. Layout em 100 cols:

```
┌ mesh setup ─────────────────────────────────────────── mac · fresh install ┐
│ TOPICS               │ Web                                    4 bundles      │
│                      │ ┌──────────────────────────────────────────────────┐ │
│   Languages   3/3    │ │  Valet           Laravel Valet — *.localhost …   │ │
│   Databases   4/4    │ │  nginx+php-fpm   nginx + php-fpm + mkcert — …  ▸ │ │
│ ▶ Web         4/4    │ │  Mailpit         Local SMTP catcher — see ev…    │ │
│   Containers  1/1    │ │  ngrok           Public HTTPS tunnel — share … ▸ │ │
│   Remote      3/4    │ └──────────────────────────────────────────────────┘ │
│   Syncthing   1/1    │ DETAIL                                                │
│   AI          5/5    │  Valet                                  will install  │
│                      │  Laravel Valet — *.localhost with HTTPS, zero config  │
│                      │  Requires: databases/mysql, databases/redis           │
│                      │  Platform: mac                                        │
├──────────────────────┴───────────────────────────────────────────────────────┤
│ INSTALL 18 · REMOVE 0 · KEEP 0                            ⏎ open  ␣ toggle    │
│ Tab pane · a all · n none · / search · ? help · q quit          Done ▸        │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Panes:**
- **Esquerda (topics tree):** lista os topics opt-in com contador `selected/total` de
  bundles. Topic focado destacado (`▶`). *Topics required (Foundation…Shell&Terminal)
  podem aparecer no topo como linhas locked `◆ always-on` (decisão aberta §6.2) ou ficar
  ocultos.*
- **Sup. direita (bundles):** bundles do topic focado, cada um com badge de estado +
  label + desc truncada + sufixo `▸` se tiver options. Header mostra topic + nº de bundles.
- **Inf. direita (detail):** detalhe do bundle focado — label, badge, desc completa,
  `Requires:`, `Platform:`. Se tiver options, dica `⏎ to configure`.

**Status bar (rodapé sup.):** delta **ao vivo** `INSTALL n · REMOVE n · KEEP n`,
recalcula a cada toggle.

**Footer (hotkeys, sempre visível):** ver §5.

**Constraint 60×20:** colapsar para **single-pane navegável** (topic → entra → lista de
bundles → entra → detail), ou esconder o pane de detail e mostrá-lo on-demand. O delta e
o footer permanecem.

---

## 3 · Tela 2 — OptionsForm (parâmetros nível-3)

Abre com `⏎` num bundle que tem options (`▸`). Modal ou tela dedicada. Renderiza os campos
do bundle e valida antes de voltar. Tipos de campo: **multiselect**, **select**, **toggle**,
**text** (pode vir pré-preenchido), **secret** (mascarado).

Exemplo — `languages/php`:

```
┌ PHP — options ──────────────────────────────────────────────┐
│  Versions to install            [✓] 8.2  [✓] 8.4  [ ] 8.5    │   multiselect (min 1)
│  Default version                ( ) 8.2  (•) 8.4             │   select
│  PECL extensions                [✓] mongodb [✓] redis        │   multiselect
│                                 [ ] imagick [ ] xdebug       │
│  Install Composer globally      [on]                         │   toggle
├──────────────────────────────────────────────────────────────┤
│  ⏎ confirm · Esc back · ␣ toggle                              │
└──────────────────────────────────────────────────────────────┘
```

**Bundles que têm options** (e os campos):

| bundle | option (label) | tipo | valores / default |
|---|---|---|---|
| `git/gitconfig` | Git author name | text | pré-preenche com o nome atual · **obrigatório** |
| `git/gitconfig` | Git author email | text | pré-preenche com o email atual · **obrigatório** |
| `git/gpg-signing` | GPG key | text | opcional (vazio = auto-pick 1ª chave) |
| `shell-terminal/shell-rc` | Default editor | select | nvim (default) · code · vim |
| `languages/node` | Configure global npm prefix | toggle | off |
| `languages/php` | Versions to install | multiselect | 8.2 · 8.3 · 8.4 (default) · 8.5 · **min 1** |
| `languages/php` | Default version | select | (deriva das versões escolhidas) |
| `languages/php` | PECL extensions | multiselect | mongodb✓ · redis✓ · imagick · xdebug |
| `languages/php` | Install Composer globally | toggle | on |
| `web/ngrok` | ngrok auth token | **secret** | opcional (mascarado) |

> **Decisão aberta (§6.3):** num fresh-install onde o bundle já vem marcado, mostramos
> esse form ou aplicamos os defaults em silêncio (ex.: pular o prompt de PHP e usar `[8.4]`)?

---

## 4 · Telas 3 e 4 — Confirm + Apply

**SummaryConfirm:** lista o delta final em 3 grupos. Confirmar / cancelar.

```
┌ Apply changes? ─────────────────────────────────────────────┐
│  INSTALL (18)   web/valet, databases/mysql, databases/redis… │
│  REMOVE  (1)    remote-access/code-server                    │
│  KEEP    (4)    git/gitconfig, shell-terminal/cli-experience…│
├──────────────────────────────────────────────────────────────┤
│  ⏎ apply · Esc back                                          │
└──────────────────────────────────────────────────────────────┘
```

**ApplyProgress:** stream de log do instalador, um `Spinner` por bundle, resumo `OK/FAIL`
no fim. **Pausa do Syncthing:** durante o apply, o bundle `syncthing` imprime a URL do admin
+ passos de pareamento e **bloqueia esperando Enter** — a tela precisa acomodar um prompt
de pausa no meio do stream (o passo manual não pode ser pulado silenciosamente).

---

## 5 · Hotkeys

**TopicPicker:** `↑↓` navega · `Tab` troca pane (topics↔bundles) · `⏎` topic: entra / bundle
com options: abre form · `␣` toggle (bundle on/off, ou topic inteiro na árvore) · `a` marcar
tudo · `n` desmarcar tudo (required permanece) · `/` busca · `?` ajuda · `q` sair sem salvar ·
`Done ▸` segue para o summary.

**OptionsForm:** `␣` toggle choice · `⏎` confirma · `Esc` volta.

---

## 6 · Regras de interação que afetam o desenho

1. **Live delta:** o contador `INSTALL/REMOVE/KEEP` no status bar atualiza a cada toggle.
2. **Cross-bundle deps — auto-select (banner):** marcar um bundle pode auto-marcar deps.
   Mostrar banner não-modal: `Auto-selected: databases/mysql, databases/redis (Valet requires)`.
   - Deps reais: `web/valet` → mysql+redis · `web/nginx-php-fpm` → php+mysql+redis ·
     `ai/claude-mobile` → `ai/claude-core`.
3. **Cross-bundle deps — removal (modal `Dialog`):** desmarcar uma dep que ainda tem
   dependente ativo abre:
   `MySQL is required by Valet.  (a) Keep MySQL selected  ·  (b) Also unselect Valet`.
4. **Required = locked:** bundles `required` mostram badge locked e ignoram `␣`/`n`.
5. **Platform:** a tela só lista bundles do **OS atual**. No mac (host de referência):
   `web/valet` e `remote-access/code-server` aparecem; `web/nginx-php-fpm`,
   `databases/mssql-driver` e specifics de WSL **não**.

### Decisões abertas (confirmar antes de finalizar)

1. Conjunto default-OFF é só `code-server` + `gpg-signing`? (candidatos: ngrok, mssql-driver, python, claude-mobile)
2. Foundation: linha locked `◆ always-on` visível, ou 100% oculta?
3. Options em bundle já-marcado no fresh: mostrar form ou usar defaults em silêncio?
4. Banner do Syncthing: imprime no terminal ou abre o admin URL (`open`/`wslview`)?

---

## 7 · DADOS REAIS — topics & bundles

12 topics. Os **5 primeiros são `required`** (sempre on; locked). Os **7 restantes são
opt-in** (marcáveis no picker). **def** = vem marcado no fresh-install (`✓`) ou não (`✗`).

### Topics (ordem do picker)

| # | order | topic | required | hint (EN) | bundles |
|---|---:|---|:--:|---|---|
| 1 | 0 | Foundation | ✓ | _(invisível)_ | 1 |
| 2 | 10 | Identity | ✓ | GitHub login + SSH — base to clone private repos | 2 |
| 3 | 20 | Dotfiles Personal | ✓ | Your identity repo: aliases, secrets, custom configs | 1 |
| 4 | 30 | Git | ✓ | git global + GPG (opt) + lazygit | 3 |
| 5 | 40 | Shell & Terminal | ✓ | zsh + 52 modern CLIs + tmux + fonts | 5 |
| 6 | 50 | Languages | — | Node, PHP, Python — opt-in per stack | 3 |
| 7 | 60 | Databases | — | MySQL, Postgres, Redis, MSSQL driver | 4 |
| 8 | 70 | Web | — | Valet/nginx + mailpit + ngrok | 4 |
| 9 | 80 | Containers | — | Docker + Compose v2 + buildx | 1 |
| 10 | 90 | Remote Access | — | sshd, mosh, Tailscale, code-server | 4 |
| 11 | 95 | Syncthing | — | P2P folder sync (manual setup afterwards) | 1 |
| 12 | 100 | AI | — | Claude CLI, Moshi, mdprobe, atomic-skills, rtk | 5 |

### Bundles (label · desc EN · flags)

Colunas: **req** = locked/sempre-on · **def** = marcado no fresh · **plat** = só nesse OS ·
**opt** = tem OptionsForm · **deps** = requires_bundles.

**Foundation** _(invisível)_
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| core | Foundation | Engine prerequisites — package manager, dirs | ✓ | — | — | — | — |

**Identity**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| gh-cli | GitHub CLI | GitHub CLI — PRs, issues, gists from the terminal | ✓ | ✓ | — | — | — |
| identity-setup | Identity setup | gh auth + SSH key + GitHub registration | ✓ | ✓ | — | — | — |

**Dotfiles Personal**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| dotfiles-personal | Dotfiles Personal | Clone your identity repo and apply MAPPINGS | ✓ | ✓ | — | — | — |

**Git**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| gitconfig | Git config | Global git config: aliases, rebase, push.default | ✓ | ✓ | — | ✓ | — |
| gpg-signing | GPG signing | Sign commits/tags — "Verified" badge on GitHub | — | **✗** | — | ✓ | — |
| lazygit-config | lazygit config | Theme + binds — consistent TUI in any repo | — | ✓ | — | — | — |

**Shell & Terminal**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| shell-rc | Shell RC | zshrc.d/bashrc.d loaders + global gitignore | ✓ | ✓ | — | ✓ | — |
| cli-experience | Modern CLI | 52 modern CLIs (fzf, bat, eza, atuin, zinit…) | ✓ | ✓ | — | — | — |
| fonts | Nerd Font | Caskaydia Nerd Font — icons in prompt/lazygit/btop | ✓ | ✓ | — | — | — |
| tmux | tmux | tmux + TPM + Catppuccin — sessions survive reboot | ✓ | ✓ | — | — | — |
| nvim-default-config | Neovim | Minimal init.lua — editor ready for commits | ✓ | ✓ | — | — | — |

**Languages**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| node | Node | fnm + Node LTS — switch versions without sudo | — | ✓ | — | ✓ | — |
| php | PHP | Multi-version PHP + Composer + PECL — `php-use` switch | — | ✓ | — | ✓ | — |
| python | Python | Python 3 + uv — fast venvs and deps | — | ✓ | — | — | — |

**Databases**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| mysql | MySQL | MySQL 8 — default relational DB for Valet/Laravel | — | ✓ | — | — | — |
| postgresql | PostgreSQL | PostgreSQL — advanced relational, native JSON | — | ✓ | — | — | — |
| redis | Redis | Redis — cache, sessions and Laravel queues | — | ✓ | — | — | — |
| mssql-driver | MS SQL driver | ODBC msodbcsql18 + sqlsrv (if PHP) — SQL Server | — | ✓ | wsl | — | — |

**Web**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| valet | Valet | Laravel Valet — *.localhost HTTPS, zero config | — | ✓ | mac | — | databases/mysql, databases/redis |
| nginx-php-fpm | nginx + php-fpm | nginx + php-fpm + mkcert — HTTPS wildcard on WSL | — | ✓ | wsl | — | languages/php, databases/mysql, databases/redis |
| mailpit | Mailpit | Local SMTP catcher — see every dev email | — | ✓ | — | — | — |
| ngrok | ngrok | Public HTTPS tunnel — share localhost for testing | — | ✓ | — | ✓ | — |

**Containers**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| docker | Docker | Colima (mac) · docker.io (WSL) + compose + buildx | — | ✓ | — | — | — |

**Remote Access**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| ssh-daemon | SSH daemon | sshd — remote access via SSH/Tailscale | — | ✓ | — | — | — |
| mosh | mosh | Mobile shell — survives flaky Wi-Fi | — | ✓ | — | — | — |
| tailscale | Tailscale | Zero-config mesh VPN — reach hosts by hostname | — | ✓ | — | — | — |
| code-server | code-server | VSCode in the browser over Tailscale — remote IDE | — | **✗** | mac | — | — |

**Syncthing**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| syncthing | Syncthing | P2P sync (claude-mem, dotfiles) — pair manually | — | ✓ | — | — | — |

**AI**
| bundle | label | desc | req | def | plat | opt | deps |
|---|---|---|:--:|:--:|---|:--:|---|
| claude-core | Claude Code | Claude Code CLI + bun + claudebar (statusline) | — | ✓ | — | — | — |
| claude-mobile | Claude mobile | Moshi-hook — reach Claude sessions on your phone | — | ✓ | — | — | ai/claude-core |
| mdprobe | mdprobe | Markdown preview in the browser — review specs/plans | — | ✓ | — | — | — |
| atomic-skills | Atomic Skills | Focused skills for Claude/Codex — reusable prompts | — | ✓ | — | — | — |
| rtk | RTK | Token-killer CLI proxy — 60–90% fewer dev tokens | — | ✓ | — | — | — |

---

*2026-05-29 · F9.6. Dados reais; só `python`/`mysql`/`redis` mac-vs-wsl e o conjunto
default-OFF têm decisões abertas (§6). Para o desenho, host de referência = **mac**.*
