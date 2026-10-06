#!/bin/bash
# Usage on each VM:  sudo ./install.sh vm-a.env   (or vm-b.env)
set -euo pipefail
ENV_FILE=${1:?usage: install.sh <vm-a.env|vm-b.env>}

apt-get update
apt-get install -y python3-venv chrony
id peermon >/dev/null 2>&1 || useradd --system --home-dir /opt/peermon --shell /usr/sbin/nologin peermon

install -d -o peermon -g peermon /opt/peermon
install -m 0644 app.py requirements.txt /opt/peermon/
python3 -m venv /opt/peermon/venv
/opt/peermon/venv/bin/pip install -q -r /opt/peermon/requirements.txt

install -m 0644 "$ENV_FILE" /etc/peermon.env
install -m 0644 peermon.service /etc/systemd/system/peermon.service
systemctl daemon-reload
systemctl enable --now peermon
sleep 2
curl -s http://127.0.0.1:8000/health; echo
