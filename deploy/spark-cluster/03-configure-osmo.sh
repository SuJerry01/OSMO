#!/usr/bin/env bash
# Configure OSMO workflow storage + pod templates + pool + creds.
# Faithful port of deployments/charts/quick-start/templates/config-setup.yaml,
# adapted for the dual-Spark k3s deploy:
#   - service in ns osmo-minimal, workflow pods in ns osmo-workflows
#     => localstack/gateway referenced by cross-namespace FQDN
#   - workflow pods pull osmo init/client images from nvcr.io (NGC creds from ~/.ngc)
#   - compute pod template targets node_group=compute (both Sparks are labeled so)
set -euo pipefail

BASE_URL="${OSMO_URL:-http://localhost:30080}"                                  # how this script reaches the API (gateway NodePort)
GW_FQDN="http://osmo-gateway.osmo-minimal.svc.cluster.local"                    # in-cluster gateway URL for workflow pods
S3_ENDPOINT="${S3_ENDPOINT:-s3://osmo}"
S3_OVERRIDE="${S3_OVERRIDE:-http://localstack-s3.osmo-minimal.svc.cluster.local:4566}"   # in-cluster (workflow pods)
S3_OVERRIDE_HOST="${S3_OVERRIDE_HOST:-http://localhost:30035}"                            # host-reachable NodePort (osmo data CLI)
S3_KEY_ID="${S3_KEY_ID:-test}"; S3_KEY="${S3_KEY:-test}"; S3_REGION="${S3_REGION:-us-east-1}"
IMG_LOC="${OSMO_IMAGE_LOCATION:-nvcr.io/nvidia/osmo}"; IMG_TAG="${OSMO_IMAGE_TAG:-latest}"
REG="nvcr.io"; REG_USER='$oauthtoken'
REG_PASS="${NGC_API_KEY:-$(awk -F= '/^apikey/{print $2}' "$HOME/.ngc/config" 2>/dev/null | tr -d ' ')}"
H=(-H "Content-Type: application/json" -H "x-osmo-user: testuser")

say(){ echo "==> $*"; }

say "workflow config (data/log/app storage + backend images + registry creds)"
curl -fsS -X PATCH "${H[@]}" "$BASE_URL/api/configs/workflow" -d @- <<JSON >/dev/null
{ "configs_dict": {
    "workflow_data": { "credential": { "endpoint": "${S3_ENDPOINT}/workflows", "override_url": "${S3_OVERRIDE}", "access_key_id": "${S3_KEY_ID}", "access_key": "${S3_KEY}", "region": "${S3_REGION}", "addressing_style": "path" } },
    "workflow_log":  { "credential": { "endpoint": "${S3_ENDPOINT}/workflows", "override_url": "${S3_OVERRIDE}", "access_key_id": "${S3_KEY_ID}", "access_key": "${S3_KEY}", "region": "${S3_REGION}", "addressing_style": "path" } },
    "workflow_app":  { "credential": { "endpoint": "${S3_ENDPOINT}/apps",      "override_url": "${S3_OVERRIDE}", "access_key_id": "${S3_KEY_ID}", "access_key": "${S3_KEY}", "region": "${S3_REGION}", "addressing_style": "path" } },
    "backend_images": { "init": "${IMG_LOC}/init-container:${IMG_TAG}", "client": "${IMG_LOC}/client:${IMG_TAG}",
                        "credential": { "registry": "${REG}", "username": "${REG_USER}", "auth": "${REG_PASS}" } },
    "credential_config": { "disable_data_validation": ["s3"] }
  }, "description": "dual-spark workflow storage" }
JSON

say "pod template (default_compute -> node_group=compute, dev login)"
curl -fsS -X PUT "${H[@]}" "$BASE_URL/api/configs/pod_template" -d @- <<'JSON' >/dev/null
{ "configs": { "default_compute": { "spec": {
    "containers": [
      { "name": "{{USER_CONTAINER_NAME}}", "env": [ { "name": "OSMO_LOGIN_DEV", "value": "true" } ] },
      { "name": "osmo-ctrl",               "env": [ { "name": "OSMO_LOGIN_DEV", "value": "true" } ] }
    ],
    "nodeSelector": { "node_group": "compute" },
    "runtimeClassName": "nvidia"
  } } }, "description": "compute pod template" }
JSON

say "pool/default common_pod_template"
curl -fsS -X PATCH "${H[@]}" "$BASE_URL/api/configs/pool/default" -d @- <<'JSON' >/dev/null
{ "configs_dict": { "common_pod_template": [ "default_ctrl", "default_user", "default_compute" ] }, "description": "pool pod templates" }
JSON

say "dataset config (default bucket osmo)"
curl -fsS -X PATCH "${H[@]}" "$BASE_URL/api/configs/dataset" -d @- <<JSON >/dev/null
{ "configs_dict": { "buckets": { "osmo": { "dataset_path": "${S3_ENDPOINT}/datasets" } }, "default_bucket": "osmo" }, "description": "dataset bucket" }
JSON

say "service base url (in-cluster gateway FQDN)"
curl -fsS -X PATCH "${H[@]}" "$BASE_URL/api/configs/service" -d @- <<JSON >/dev/null
{ "configs_dict": { "service_base_url": "${GW_FQDN}" }, "description": "service base url" }
JSON

say "wait for backend 'default'"
until curl -fsS "$BASE_URL/api/configs/backend/default" >/dev/null 2>&1; do echo "   backend not ready..."; sleep 5; done

say "set profile default pool"
curl -fsS -X POST "${H[@]}" "$BASE_URL/api/profile/settings" -d '{"pool":"default"}' >/dev/null

say "set data credential"
curl -fsS -X POST "${H[@]}" "$BASE_URL/api/credentials/osmo" -d @- <<JSON >/dev/null
{ "data_credential": { "access_key_id": "${S3_KEY_ID}", "access_key": "${S3_KEY}", "endpoint": "${S3_ENDPOINT}", "override_url": "${S3_OVERRIDE_HOST}", "region": "${S3_REGION}", "addressing_style": "path" } }
JSON

say "OSMO configuration complete."
