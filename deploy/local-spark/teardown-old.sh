#!/usr/bin/env bash
# Non-sudo cleanup of the OLD OSMO footprint (docker deps + client config).
# The k3s removal itself is sudo — see sudo-commands.md section A.
set -uo pipefail

echo "==> Stop & remove old OSMO docker dependencies"
for c in osmo-postgres osmo-redis osmo-minio registry; do
  docker rm -f "$c" 2>/dev/null && echo "   removed container $c" || echo "   (no container $c)"
done

echo "==> Remove dangling old OSMO volumes (named)"
docker volume ls -q 2>/dev/null | grep -iE 'osmo|minio|registry' | while read -r v; do
  docker volume rm "$v" 2>/dev/null && echo "   removed volume $v" || true
done

echo "==> Remove old OSMO client config/state"
rm -rf /home/spark/.config/osmo /home/spark/.local/state/osmo
echo "   removed ~/.config/osmo and ~/.local/state/osmo"

echo "==> Done (non-sudo portion). Now run sudo-commands.md section A for k3s/CLI/hosts."
