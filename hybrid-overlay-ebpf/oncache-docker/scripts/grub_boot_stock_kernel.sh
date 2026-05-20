#!/usr/bin/env bash
# Run ON THE HOST (e.g. via Hetzner KVM console) if oncache-rpeer kernel will not boot.
set -euo pipefail

STOCK="Advanced options for Ubuntu>Ubuntu, with Linux 5.15.0-139-generic"
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${STOCK}\"|" /etc/default/grub
update-grub
echo "GRUB set to boot: ${STOCK}"
echo "Run: reboot"
