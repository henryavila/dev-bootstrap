# 90-editor (opt-in)

Ativado com `INCLUDE_EDITOR=1 bash bootstrap.sh`.

Instala `~/.local/bin/typora-wait` — wrapper que abre um arquivo em Typora e bloqueia até o fechamento, para usar como `$EDITOR`:

```bash
export EDITOR=typora-wait
git commit       # abre em Typora, só retorna quando fechar
```

**Pré-requisito:** Typora instalado manualmente (GUI). Em Mac via `brew install --cask typora`; no Linux/WSL, baixar do site oficial.
