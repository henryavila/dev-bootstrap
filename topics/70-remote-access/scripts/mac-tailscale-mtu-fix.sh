#!/usr/bin/env bash
# mac-tailscale-mtu-fix.sh — seta MTU 1200 na interface Tailscale do macOS.
#
# Contexto: OpenSSH 9.6+ negocia sntrup761x25519-sha512 (KEX pós-quântico)
# que gera pacotes ~3-4 KB. O túnel WireGuard do Tailscale tem MTU 1280
# default — fragmentação silenciosa faz SSH travar em SSH2_MSG_KEX_ECDH_REPLY.
# Reduzir MTU para 1200 elimina o gap.
#
# Por que não é automatizado no install.mac.sh:
# - Tailscale no macOS é distribuído como .app (GUI), instalada via brew cask.
#   O daemon é gerenciado pela própria app; não tem systemd drop-in equivalente.
# - A interface Tailscale é `utun<N>` onde N varia a cada sessão.
# - LaunchDaemon rodando em cada boot + watch de network.plist funcionaria
#   mas é invasivo. Abordagem escolhida: script manual, rodar on-demand.
#
# Uso:
#   sudo bash mac-tailscale-mtu-fix.sh          # seta MTU 1200 agora (não persiste)
#   # Para persistir: rodar novamente após reboot ou re-login.
#   # Para automatizar: instalar como LaunchDaemon (exemplo no README).

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "! este script precisa de sudo: sudo bash $0"
    exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
    echo "! tailscale CLI não encontrado — instale Tailscale.app primeiro"
    exit 1
fi

# Descobre a interface Tailscale. tailscale status imprime o IP da interface
# mas não o nome do device. Usa ifconfig para encontrar o utun com esse IP.
ts_ip4="$(tailscale ip -4 2>/dev/null || true)"
if [[ -z "$ts_ip4" ]]; then
    echo "! tailscale IP não encontrado — rode 'tailscale up' primeiro"
    exit 1
fi

# Busca qual utun tem esse IP atribuído
ts_iface=""
for iface in $(ifconfig -l); do
    if [[ "$iface" == utun* ]]; then
        if ifconfig "$iface" 2>/dev/null | grep -qF "inet $ts_ip4"; then
            ts_iface="$iface"
            break
        fi
    fi
done

if [[ -z "$ts_iface" ]]; then
    echo "! não foi possível identificar a interface Tailscale (IP $ts_ip4)"
    exit 1
fi

current_mtu="$(ifconfig "$ts_iface" | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
echo "→ Interface Tailscale: $ts_iface (MTU atual: $current_mtu)"

if [[ "$current_mtu" == "1200" ]]; then
    echo "✓ MTU já é 1200 — nada a fazer"
    exit 0
fi

echo "→ Setando MTU $ts_iface -> 1200"
ifconfig "$ts_iface" mtu 1200

echo "✓ MTU setado. Validar com: ifconfig $ts_iface | grep mtu"
echo "! Este ajuste NÃO persiste entre reboots/re-logins."
echo "  Re-rodar este script após boot, ou instalar como LaunchDaemon (ver README)."
