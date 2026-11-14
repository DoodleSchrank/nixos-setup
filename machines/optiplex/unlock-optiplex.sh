#!/usr/bin/env bash
# Unlock the Optiplex's System disk from the PC over the home LAN (ADR 0002, amended).
#
# The LUKS passphrase is read from secrets/luks.yaml (key `luks_passphrase`, encrypted to the
# yannik age key only, so the PC's sops key is the only way to read it). It is piped straight into
# the initrd's systemd password agent over SSH; it never touches the disk in clear and never goes
# on the command line.
#
# usage: machines/optiplex/unlock-optiplex.sh [host]
#   host defaults to 192.168.178.20, the initrd's static LAN address. Port 2222 is never forwarded.
set -euo pipefail

HOST="${1:-192.168.178.20}"
PORT=2222
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SECRET="$REPO/secrets/luks.yaml"
# The initrd host key is a dedicated key, not the Optiplex's main one; keep its own known_hosts.
KNOWN_HOSTS="$HOME/.ssh/known_hosts.optiplex-initrd"

if [ ! -e "$SECRET" ]; then
  echo "unlock: $SECRET does not exist (see the LUKS passphrase to-do)" >&2
  exit 1
fi

# sops prints the value without a trailing newline, which the password agent expects.
sops -d --extract '["luks_passphrase"]' "$SECRET" \
  | ssh -p "$PORT" \
      -o UserKnownHostsFile="$KNOWN_HOSTS" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "root@$HOST" 'systemd-tty-ask-password-agent --query'

echo "unlock: passphrase sent to the initrd on $HOST:$PORT; the boot continues."
