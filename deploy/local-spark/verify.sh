#!/usr/bin/env bash
# End-to-end verification of the local OSMO deployment.
set -uo pipefail
OSMO_URL="${OSMO_URL:-http://quick-start.osmo}"

echo "==> Cluster nodes"; kubectl get nodes -o wide
echo "==> GPU operator pods"; kubectl get pods -n gpu-operator 2>/dev/null
echo "==> KAI scheduler pods"; kubectl get pods -n kai-scheduler 2>/dev/null
echo "==> OSMO pods"; kubectl get pods -n osmo

echo "==> UI reachability"; curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$OSMO_URL" || true

echo "==> osmo CLI login (dev)"
osmo login "$OSMO_URL" --method=dev --username=testuser

echo "==> Submit smoke-test workflow (verify-hello)"
osmo workflow submit ../../deployments/workflows/verify-hello.yaml
osmo workflow list

echo
echo "If you have GPU compute scheduled, also try:"
echo "  osmo workflow submit ../../deployments/workflows/verify-gpu.yaml"
