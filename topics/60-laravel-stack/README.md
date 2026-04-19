# 60-laravel-stack (opt-in)

Ativado com `INCLUDE_LARAVEL=1 bash bootstrap.sh`.

**Instala:** MySQL, Redis, Nginx, PHP-FPM 8.4 (WSL) / Nginx + PHP via `10-languages` (Mac), mkcert.

**Deploys (via `DEPLOY` file):**
- `nginx-catchall.conf` — serve `*.localhost` → `$CODE_DIR/<project>/public`. `$CODE_DIR` e caminho do FPM socket são expandidos via `envsubst`.
- `~/.local/bin/link-project` — CLI helper: `link-project foo` → cria entrada `foo.localhost` no hosts (WSL) e avisa se o diretório `public/` não existe.

**Env vars:** `CODE_DIR` (default `~/code/web`), `BREW_PREFIX` (Mac), `NGINX_CONF_DIR` (derivado por `install.$OS.sh`).

**Pós-install:** no WSL, iniciar serviços manualmente:
```
sudo systemctl start mysql redis nginx php8.4-fpm
```
No Mac, `brew services` já foi chamado pelo installer.
