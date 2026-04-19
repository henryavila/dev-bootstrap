# 70-remote-access (opt-in)

Ativado com `INCLUDE_REMOTE=1 bash bootstrap.sh`.

**Instala:** `openssh-server` + `mosh` + `tailscale`. Ativa sshd, habilita systemd no WSL (`/etc/wsl.conf`) e cria sudoers NOPASSWD para o usuário atual.

**Deploys:**
- `/etc/ssh/sshd_config.d/99-${USER}.conf` com hardening (PasswordAuth off, PubkeyAuth on, AllowUsers restrito).
  `envsubst` expande `${USER}`. `lib/deploy.sh` detecta o path fora de `$HOME` e eleva via sudo automaticamente.

**Pós-install:**
1. Sair e rodar `wsl --shutdown` (Windows) para aplicar systemd.
2. `sudo tailscale up` para autenticar.
3. Copiar chave pública no `~/.ssh/authorized_keys` do usuário.

**Gotcha:** SSH em Tailscale + KEX pós-quântico pode travar se MTU do WireGuard for menor que o pacote. Ver `docs/ssh-tailscale-mtu.md` em `dotfiles-template`.
