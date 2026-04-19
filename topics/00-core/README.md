# 00-core

Instala as ferramentas mínimas que todo topic posterior assume e que o próprio runner depende.

**Pacotes WSL:** `git curl wget ca-certificates gnupg build-essential jq unzip gettext-base`
**Pacotes macOS:** `git curl wget gnupg jq unzip gettext` (+ instala Homebrew se ausente)

**Sem templates** — este topic não pode depender de `lib/deploy.sh`, porque o `deploy.sh` usa `envsubst`, que este topic instala. Qualquer configuração shell correspondente mora em `30-shell`.

**Customização:** edite `install.$OS.sh` para adicionar pacotes mínimos usados em todo lugar.
