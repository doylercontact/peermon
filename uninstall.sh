#!/bin/bash
# Usage:  sudo ./uninstall.sh [--purge]
#   Removes peermon: service, firewall rules, code, commands and settings.
#   Keeps the check history in /var/lib/peermon (your test evidence)
#   unless --purge is given, which also deletes it and the peermon user.
# Safe to run more than once.
set -uo pipefail

PURGE=0
case "${1:-}" in
  --purge)   PURGE=1 ;;
  -h|--help) sed -n '2,6p' "$0" | sed 's/^# //'; exit 0 ;;
  "")        ;;
  *)         echo "usage: sudo ./uninstall.sh [--purge]" >&2; exit 2 ;;
esac
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }

echo "stopping peermon"
systemctl disable --now peermon.service >/dev/null 2>&1 || true

echo "removing host firewall rules"
if [ -x /usr/local/bin/peermon-firewall ]; then
  /usr/local/bin/peermon-firewall disable >/dev/null 2>&1 || true
fi
systemctl disable --now peermon-firewall.service >/dev/null 2>&1 || true
nft delete table inet peermon >/dev/null 2>&1 || true

echo "removing files"
rm -f /etc/systemd/system/peermon.service /etc/systemd/system/peermon-firewall.service
systemctl daemon-reload >/dev/null 2>&1 || true
rm -rf /opt/peermon
rm -f /usr/local/bin/peermonctl /usr/local/bin/peermon-firewall /etc/peermon.env

if [ "$PURGE" -eq 1 ]; then
  echo "purging history and the peermon user"
  rm -rf /var/lib/peermon /var/lib/private/peermon
  userdel peermon >/dev/null 2>&1 || true
  echo "peermon removed completely"
else
  echo "peermon removed; history kept in /var/lib/peermon (sudo ./uninstall.sh --purge to delete it)"
fi
