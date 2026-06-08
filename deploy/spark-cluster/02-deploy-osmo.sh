#!/usr/bin/env bash
# One-shot (non-sudo) OSMO layer deploy on the dual-Spark k3s cluster.
# Prereq: k3s 2-node cluster up + kubeconfig at ~/.kube/config (see 01-build-k3s-2node.md).
# Idempotent where practical. Run from this directory.
set -euo pipefail
cd "$(dirname "$0")"; HERE="$(pwd)"; REPO="$(cd ../.. && pwd)"
NS_SVC=osmo-minimal; NS_OP=osmo-operator; NS_WF=osmo-workflows
OSMO_URL="${OSMO_URL:-http://localhost:30080}"
OSMO_CLI_REF="${OSMO_CLI_REF:-6.3.0-prerelease-rc11}"
NGC_API_KEY="${NGC_API_KEY:-$(awk -F= '/^apikey/{print $2}' "$HOME/.ngc/config" 2>/dev/null | tr -d ' ')}"
[ -n "$NGC_API_KEY" ] || { echo "NGC_API_KEY not found (~/.ngc/config)"; exit 1; }
say(){ echo "==> $*"; }

say "1) namespaces"
for ns in $NS_SVC $NS_OP $NS_WF; do kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns"; done

say "2) nvcr.io pull secret (all 3 ns)"
for ns in $NS_SVC $NS_OP $NS_WF; do
  kubectl -n "$ns" create secret docker-registry nvcr-secret --docker-server=nvcr.io \
    --docker-username='$oauthtoken' --docker-password="$NGC_API_KEY" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

say "3) db-secret / redis-secret / mek-config (osmo-minimal)"
kubectl -n $NS_SVC create secret generic db-secret --from-literal=db-password=osmo --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n $NS_SVC create secret generic redis-secret --from-literal=redis-password='' --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n $NS_SVC get configmap mek-config >/dev/null 2>&1; then
  RK=$(openssl rand -base64 32 | tr -d '\n'); EK=$(printf '{"k":"%s","kid":"key1","kty":"oct"}' "$RK" | base64 | tr -d '\n')
  kubectl -n $NS_SVC create configmap mek-config --from-literal=mek.yaml="$(printf 'currentMek: key1\nmeks:\n  key1: %s\n' "$EK")"
fi

say "4) GPU device plugin + node labels (both Sparks)"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true; helm repo update nvdp >/dev/null
helm upgrade --install nvdp nvdp/nvidia-device-plugin -n nvidia-device-plugin --create-namespace --set runtimeClassName=nvidia --wait >/dev/null
kubectl label node --all nvidia.com/gpu.present=true node_group=compute --overwrite >/dev/null

say "5) KAI scheduler (official idempotent script)"
bash "$REPO/deployments/scripts/install-kai-scheduler.sh"

say "6) OSMO service chart (in-cluster PG/Redis/localstack)"
helm upgrade --install osmo-minimal "$REPO/deployments/charts/service" -n $NS_SVC -f "$HERE/osmo-service-values.yaml" --wait --timeout 10m

say "7) OSMO CLI (userspace, no sudo) if missing"
if ! command -v osmo >/dev/null 2>&1; then
  t=$(mktemp -d); u="https://github.com/NVIDIA/OSMO/releases/download/${OSMO_CLI_REF}/osmo-client-installer-${OSMO_CLI_REF}-linux-arm64.sh"
  curl -sfL --retry 2 "$u" -o "$t/i.sh"
  ln=$(grep -a -n -m1 '^__ARCHIVE_BELOW__' "$t/i.sh" | cut -d: -f1)
  tail -n +$((ln+1)) "$t/i.sh" | tar -xz -C "$t"
  rm -rf "$HOME/.local/osmo"; mkdir -p "$HOME/.local" "$HOME/bin"; cp -r "$t/osmo" "$HOME/.local/osmo"
  ln -sf "$HOME/.local/osmo/osmo" "$HOME/bin/osmo"; rm -rf "$t"
  export PATH="$HOME/bin:$PATH"
fi
osmo version

say "8) login (dev)"
osmo login "$OSMO_URL" --method=dev --username=testuser

say "9) backend-operator token + secret + chart"
osmo user create backend-operator --roles osmo-backend 2>/dev/null || true
TOKEN=$(osmo token set backend-token --user backend-operator --expires-at 2027-01-01 \
          --description "Backend Operator Token" --roles osmo-backend -t json | jq -r '.token')
kubectl -n $NS_OP create secret generic osmo-operator-token --from-literal=token="$TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
helm upgrade --install osmo-operator "$REPO/deployments/charts/backend-operator" -n $NS_OP -f "$HERE/osmo-backend-operator-values.yaml" --wait --timeout 5m

say "10) configure workflow storage / pod templates / pool / creds"
NGC_API_KEY="$NGC_API_KEY" OSMO_URL="$OSMO_URL" bash "$HERE/03-configure-osmo.sh"

say "DONE. Verify:"
echo "   osmo workflow submit $REPO/deployments/workflows/verify-hello.yaml"
echo "   osmo workflow list ; osmo resource list ; open $OSMO_URL"
