#!/usr/bin/env bash
# Non-sudo cleanup of the OLD OSMO footprint (docker deps + client config).
#
# Deliberately does NOT touch:
#   - the local `registry` container  (shared: also holds gr00t / isaac-lab images)
#   - the k3s cluster                 (sudo — see sudo-commands.md section A)
#   - /data/osmo/postgres             (root-owned — see sudo-commands.md section A)
set -uo pipefail

echo "==> Stop & remove OSMO-only docker dependencies (with anonymous volumes)"
for c in osmo-postgres osmo-redis osmo-minio; do
  docker rm -fv "$c" 2>/dev/null && echo "   removed container+anonvol: $c" || echo "   (no container $c)"
done

echo "==> Remove MinIO bind-mount data (owned by spark)"
rm -rf /mnt/osmo-minio && echo "   removed /mnt/osmo-minio" || echo "   could not remove /mnt/osmo-minio"

echo "==> Remove old OSMO client config/state"
rm -rf /home/spark/.config/osmo /home/spark/.local/state/osmo
echo "   removed ~/.config/osmo and ~/.local/state/osmo"

echo
echo "==> Done (non-sudo portion)."
echo "    Still TODO (sudo) — see sudo-commands.md section A:"
echo "      sudo rm -rf /data/osmo            # root-owned Postgres data"
echo "      sudo /usr/local/bin/k3s-uninstall.sh"
echo "      sudo rm -f /usr/local/bin/osmo && sudo rm -rf /usr/local/osmo"
echo "      sudo sed -i '/osmo-registry\\.spark\\.local/d' /etc/hosts"
