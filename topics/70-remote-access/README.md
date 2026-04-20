# 70-remote-access (opt-in)

Ativado com `INCLUDE_REMOTE=1 bash bootstrap.sh`.

**Instala:** `openssh-server` + `mosh` + `tailscale`. Ativa sshd, habilita systemd no WSL (`/etc/wsl.conf`) e cria sudoers NOPASSWD para o usuário atual.

**Aplica (WSL):** drop-in systemd para corrigir MTU do tailscale0 — ver seção "Tailscale MTU gotcha" abaixo.

**Deploys:**
- `/etc/ssh/sshd_config.d/99-${USER}.conf` com hardening (PasswordAuth off, PubkeyAuth on, AllowUsers restrito).
  `envsubst` expande `${USER}`. `lib/deploy.sh` detecta o path fora de `$HOME` e eleva via sudo automaticamente.
- **(WSL)** `/etc/systemd/system/tailscaled.service.d/mtu.conf` — drop-in que roda `ip link set tailscale0 mtu 1200` a cada start do `tailscaled`. Idempotente: só reescreve se conteúdo difere.

**Pós-install:**
1. Sair e rodar `wsl --shutdown` (Windows) para aplicar systemd.
2. `sudo tailscale up` para autenticar.
3. Copiar chave pública no `~/.ssh/authorized_keys` do usuário.

---

## Tailscale MTU gotcha (SSH KEX pós-quântico)

### Sintoma

`ssh <host>` via Tailscale trava indefinidamente em `SSH2_MSG_KEX_ECDH_REPLY`, mesmo com `tailscale ping` respondendo em <10ms. Afeta apenas conexões com OpenSSH 9.6+ (que negocia KEX pós-quântico por padrão).

### Causa

Pipeline do bug:

1. Tailscale usa WireGuard com MTU 1280 (default).
2. OpenSSH 9.6+ negocia `sntrup761x25519-sha512@openssh.com` → mensagens KEX ~3–4 KB.
3. No túnel MTU 1280, sem Path MTU Discovery confiável, fragmentos grandes se perdem silenciosamente.
4. Cliente espera `KEX_ECDH_REPLY` que nunca chega → timeout após ~2min.

Reduzir MTU **cliente-side via `~/.ssh/config` (`KexAlgorithms curve25519`) sozinho NÃO resolve** — hostkeys, banners e outras mensagens do handshake também podem exceder MTU.

### Fix aplicado (WSL — automatizado)

Este topic grava em `/etc/systemd/system/tailscaled.service.d/mtu.conf`:

```ini
[Service]
ExecStartPost=/usr/sbin/ip link set tailscale0 mtu 1200
```

O drop-in roda **toda vez** que `tailscaled` inicia, então persiste reboots + re-installs do Tailscale. Custo teórico em throughput dentro do túnel: ~6%. Imperceptível em uso SSH/mosh.

Idempotência: install.wsl.sh lê o arquivo antes de reescrever — se já tem o conteúdo exato, não toca. Se difere, reescreve + `daemon-reload` + (se `tailscaled` ativo) `restart tailscaled`.

### Fix no macOS (manual)

Tailscale no Mac é distribuído como `.app` (via `brew install --cask tailscale`). O daemon é gerenciado pela app; sem drop-in systemd equivalente. A interface é `utun<N>` com N variável.

O topic instala `scripts/mac-tailscale-mtu-fix.sh` que:
1. Detecta a interface Tailscale atual (via `tailscale ip -4` + `ifconfig` scan das `utun*`).
2. Roda `ifconfig <utun> mtu 1200`.

**Uso on-demand** (se experimentar hang em SSH via Tailscale):

```bash
sudo bash ~/dev-bootstrap/topics/70-remote-access/scripts/mac-tailscale-mtu-fix.sh
```

Não persiste reboot — re-rodar após boot ou re-login. Para automação persistente, criar LaunchDaemon custom que rode o script a cada inicialização (TODO — não automatizado para não ser invasivo com a app gerenciada pelo usuário).

### Verificação

- **WSL**: `ip link show tailscale0` deve mostrar `mtu 1200`. O `verify.sh` deste topic checa o drop-in + o MTU aplicado se a interface estiver up.
- **Mac**: `ifconfig utun<N> | grep mtu` onde `<N>` é a interface Tailscale atual.

### Referências

Diagnóstico detalhado + variações conhecidas em `ssh-tailscale-mtu-gotcha.md` (memory file do dotfiles pessoal).

---

## Skip

Se você não usa Tailscale nem mosh:

```bash
# não setar INCLUDE_REMOTE=1 (default skip)
bash bootstrap.sh
```
