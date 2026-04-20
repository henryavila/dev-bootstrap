# 80-claude-code

Instala duas ferramentas que compõem o "Claude stack" cross-machine:

## 1. Claude Code CLI

Via installer oficial: `curl -fsSL https://claude.ai/install.sh | bash`. Binário fica em `~/.local/bin/claude` (PATH já coberto pelo topic `30-shell`).

**Login:** após instalar, rodar `claude` e autenticar uma vez por máquina (OAuth com Anthropic — não transferível).

## 2. Syncthing (P2P file sync daemon)

Usado para sincronizar um subset curado de `~/.claude/` e `~/.claude-mem/` entre N máquinas pessoais, **sem cloud intermediário**. O daemon roda como serviço user-level e descobre outros peers via LAN + STUN/relay.

**Instalação:**

- **WSL / Linux**: `sudo apt-get install syncthing`; habilita `systemctl --user enable --now syncthing.service` + `loginctl enable-linger $USER` (pra rodar após logout).
- **macOS**: `brew install syncthing`; inicia via `brew services start syncthing`.

**Web UI:** http://localhost:8384 — primeira etapa de uso:
1. Setar senha admin em *Settings → GUI* (mesmo acessando só localhost)
2. Pegar o device ID: `syncthing --device-id`
3. Pairing com outras máquinas + aceitar folders compartilhadas

**Fluxo de pairing + folders** (o que sincronizar, com que `.stignore`): documentado em `~/dotfiles/claude/scripts/syncthing-setup.md` quando o dotfiles do usuário estiver clonado (topic `95-dotfiles-personal`).

## Separação de responsabilidades

Este topic instala **ferramentas** (CLI + daemon). O *conteúdo* (o quê sincronizar, como configurar o daemon, qual `.stignore` usar) vem do **dotfiles pessoal** via `95-dotfiles-personal`.

## Skip

Se você não usa Claude Code ou prefere tratar o syncthing fora do bootstrap:

```bash
SKIP_TOPICS="80-claude-code" bash bootstrap.sh
```
