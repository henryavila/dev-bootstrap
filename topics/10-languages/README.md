# 10-languages

Instala runtimes de linguagem:

- **Node LTS** via `fnm` (WSL: installer oficial; Mac: brew)
- **PHP 8.4** + extensões comuns (WSL: PPA `ondrej/php`; Mac: `brew install php@8.4`)
- **Composer** (WSL: installer oficial com verificação de checksum; Mac: brew)
- **Python corrente** (WSL: `python3` apt; Mac: `python@3.13` brew)

Os fragments em `templates/` configuram `fnm env --use-on-cd` e o `PATH` do Composer para bash e zsh.

**Customização:** trocar versão do PHP editando `install.*.sh`. Para versões múltiplas de Node, use `fnm use <versão>` por projeto.
