#!/usr/bin/env bash
set -euo pipefail

# ========= CONFIG =========
WG_ADDR="10.200.0.3/24"
CP1_PUBLIC_IP="45.38.228.63"
CP1_WG_PORT="51820"

# Paste cp1 public key here AFTER you run setup on cp1 and collect its key
CP1_PUBKEY="PASTE_CP1_PUBLIC_KEY_HERE"
# ==========================

echo "[w2] Installing WireGuard..."
sudo apt-get update -y
sudo apt-get install -y wireguard

echo "[w2] Generating keys (if missing)..."
umask 077
if [[ ! -f "$HOME/wg.key" ]]; then
  wg genkey | tee "$HOME/wg.key" | wg pubkey > "$HOME/wg.pub"
fi

echo "[w2] Public key:"
cat "$HOME/wg.pub"
echo

if [[ "$CP1_PUBKEY" == PASTE_* ]]; then
  echo "[w2] ERROR: You must paste CP1_PUBKEY into this script first."
  exit 1
fi

echo "[w2] Writing /etc/wireguard/wg0.conf ..."
sudo tee /etc/wireguard/wg0.conf >/dev/null <<EOF
[Interface]
Address = ${WG_ADDR}
PrivateKey = $(cat "$HOME/wg.key")

[Peer]
PublicKey = ${CP1_PUBKEY}
Endpoint = ${CP1_PUBLIC_IP}:${CP1_WG_PORT}
AllowedIPs = 10.200.0.0/24
PersistentKeepalive = 25
EOF

sudo chmod 600 /etc/wireguard/wg0.conf
echo "[w2] Done."
