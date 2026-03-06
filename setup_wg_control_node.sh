#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
WG_ADDR="10.200.0.1/24"
WG_LISTEN_PORT="51820"

# Paste worker public keys here AFTER you run setup on workers and collect their keys
W1_PUBKEY="PASTE_W1_PUBLIC_KEY_HERE"
W2_PUBKEY="PASTE_W2_PUBLIC_KEY_HERE"
# ==========================

echo "[cp1] Installing WireGuard..."
sudo apt-get update -y
sudo apt-get install -y wireguard

echo "[cp1] Generating keys (if missing)..."
umask 077
if [[ ! -f "$HOME/wg.key" ]]; then
  wg genkey | tee "$HOME/wg.key" | wg pubkey > "$HOME/wg.pub"
fi

echo "[cp1] Public key:"
cat "$HOME/wg.pub"
echo

if [[ "$W1_PUBKEY" == PASTE_* || "$W2_PUBKEY" == PASTE_* ]]; then
  echo "[cp1] ERROR: You must paste W1_PUBKEY and W2_PUBKEY into this script first."
  exit 1
fi

echo "[cp1] Writing /etc/wireguard/wg0.conf ..."
sudo tee /etc/wireguard/wg0.conf >/dev/null <<EOF
[Interface]
Address = ${WG_ADDR}
ListenPort = ${WG_LISTEN_PORT}
PrivateKey = $(cat "$HOME/wg.key")

# w1
[Peer]
PublicKey = ${W1_PUBKEY}
AllowedIPs = 10.200.0.2/32

# w2
[Peer]
PublicKey = ${W2_PUBKEY}
AllowedIPs = 10.200.0.3/32
EOF

sudo chmod 600 /etc/wireguard/wg0.conf
echo "[cp1] Done."
