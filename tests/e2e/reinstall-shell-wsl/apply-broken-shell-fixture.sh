#!/usr/bin/env bash
# Recreate the pre-0e30b18 WSL shell failure:
# chsh flipped to zsh before mesh ~/.zshrc existed, so login zsh has stock rc
# and fzf is wired only via Debian bash-completion.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "must run as root" >&2
    exit 1
fi

GATE_USER="${GATE_USER:-gate}"

if ! id "$GATE_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$GATE_USER"
fi

echo "${GATE_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${GATE_USER}-gate"
chmod 440 "/etc/sudoers.d/${GATE_USER}-gate"

cat > /etc/wsl.conf <<EOF
[user]
default=${GATE_USER}
EOF

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq zsh fzf git curl ca-certificates bash-completion

chsh -s /usr/bin/zsh "$GATE_USER"

home="$(getent passwd "$GATE_USER" | cut -d: -f6)"
rm -rf "$home/.zshrc" "$home/.zshrc.d" "$home/.p10k.zsh" \
    "$home/.zinit" "$home/.local/share/zinit"

chown -R "${GATE_USER}:${GATE_USER}" "$home"

echo "FIXTURE_OK"
getent passwd "$GATE_USER"
echo "zsh=$(command -v zsh)"
echo "fzf=$(command -v fzf)"
echo "home listing:"
ls -la "$home"
