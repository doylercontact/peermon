#!/bin/bash
# Usage on each VM:  sudo ./install.sh [--firewall] vm-a.env    (or vm-b.env)
#   --firewall   also restrict tcp/8000 to the peer and FIREWALL_ALLOW hosts
# Safe to re-run: updates the code and settings in place and restarts peermon.
set -euo pipefail

FIREWALL=0
ENV_FILE=""
for arg in "$@"; do
  case "$arg" in
    --firewall) FIREWALL=1 ;;
    -h|--help)  sed -n '2,4p' "$0" | sed 's/^# //'; exit 0 ;;
    *)          ENV_FILE=$arg ;;
  esac
done
[ -n "$ENV_FILE" ] || { echo "usage: sudo ./install.sh [--firewall] <vm-a.env|vm-b.env>" >&2; exit 2; }
[ -r "$ENV_FILE" ] || { echo "cannot read $ENV_FILE" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 2; }
ENV_FILE=$(realpath "$ENV_FILE")
cd "$(dirname "$(realpath "$0")")"

apt-get update
apt-get install -y python3-venv chrony nftables
id peermon >/dev/null 2>&1 || useradd --system --home-dir /opt/peermon --shell /usr/sbin/nologin peermon

install -d -o peermon -g peermon /opt/peermon
install -m 0644 app.py requirements.txt /opt/peermon/
[ -x /opt/peermon/venv/bin/python ] || python3 -m venv /opt/peermon/venv
/opt/peermon/venv/bin/pip install -q -r /opt/peermon/requirements.txt

install -m 0644 "$ENV_FILE" /etc/peermon.env
install -m 0755 peermonctl peermon-firewall /usr/local/bin/
install -m 0644 peermon.service peermon-firewall.service /etc/systemd/system/
systemctl daemon-reload

if [ "$FIREWALL" -eq 1 ]; then
  peermon-firewall enable
fi

systemctl enable peermon >/dev/null 2>&1
systemctl restart peermon
sleep 2
peermonctl health --local --pretty || true
echo
peermon-firewall status | sed -n "1,2p"
[ "$FIREWALL" -eq 1 ] || echo "(host firewall not enabled; to enable later: sudo peermon-firewall enable)"
