#!/usr/bin/env bash
# OSMO local deploy on DGX Spark (KIND/nvkind + quick-start chart)
# Follows docs/deployment_guide/appendix/deploy_local.rst (Option A: GPU).
# Non-sudo. Run AFTER:
#   - old k3s/OSMO removed (see sudo-commands.md section A)
#   - kind + nvkind on PATH (see sudo-commands.md section C)
#   - inotify limits raised (sudo-commands.md section B)
set -euo pipefail
cd "$(dirname "$0")"

GPU_OPERATOR_VERSION="v25.10.0"
KAI_VERSION="v0.12.10"

echo "==> [1/4] Create GPU KIND cluster via nvkind"
nvkind cluster create --config-template=kind-osmo-cluster-config.yaml
echo "    verify GPUs:"
nvkind cluster print-gpus

echo "==> [2/4] Install NVIDIA GPU Operator (${GPU_OPERATOR_VERSION})"
helm fetch "https://helm.ngc.nvidia.com/nvidia/charts/gpu-operator-${GPU_OPERATOR_VERSION}.tgz"
helm upgrade --install gpu-operator "gpu-operator-${GPU_OPERATOR_VERSION}.tgz" \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=false --set toolkit.enabled=false --set nfd.enabled=true \
  --wait

echo "==> [3/4] Install KAI Scheduler (${KAI_VERSION})"
helm upgrade --install kai-scheduler \
  oci://ghcr.io/nvidia/kai-scheduler/kai-scheduler --version "${KAI_VERSION}" \
  --create-namespace -n kai-scheduler \
  --set global.nodeSelector.node_group=kai-scheduler \
  --set "scheduler.additionalArgs[0]=--default-staleness-grace-period=-1s" \
  --set "scheduler.additionalArgs[1]=--update-pod-eviction-condition=true" \
  --wait

echo "==> [4/4] Install OSMO (quick-start chart)"
helm repo add osmo https://helm.ngc.nvidia.com/nvidia/osmo 2>/dev/null || true
helm repo update
helm upgrade --install osmo osmo/quick-start \
  --namespace osmo --create-namespace --wait

echo
echo "==> Done. Watch pods:  kubectl get pods -n osmo -w"
echo "    UI:               http://quick-start.osmo  (needs '127.0.0.1 quick-start.osmo' in /etc/hosts)"
echo "    Login:            osmo login http://quick-start.osmo --method=dev --username=testuser"
