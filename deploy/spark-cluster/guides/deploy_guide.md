# OSMO Deploy Guide — Dual DGX Spark (k3s, on-prem)

A complete, reproducible guide for deploying **OSMO 6.3** on a **two-node DGX Spark**
Kubernetes cluster, as actually built on this machine. Organized from the official
[Deployment Guide](https://nvidia.github.io/OSMO/main/deployment_guide/) and adapted for
real dual-node Spark hardware (the official "Local Deployment" uses single-machine KIND,
which we deliberately did **not** use — see §1).

---

## 1. Why this shape (KIND vs k3s)

OSMO's official local path = KIND (simulated nodes) + `nvkind` for GPU + `quick-start` chart.
That's for **single-machine evaluation**. We needed **production, two real Sparks, real GPU**, so:

- **Substrate = k3s** across the two Sparks (not KIND's nested docker nodes).
- **GPU = NVIDIA device plugin + `nvidia` runtimeclass** (not `nvkind`; nvkind's GPU injection
  fails on this ARM64 host: KIND 0.32 containerd v2.3.1 vs `nvidia-ctk` v4 config conflict).
- **OSMO = `service` + `backend-operator` charts** (the `deploy_minimal` path), which impose no
  `node_group` topology and run in-cluster Postgres/Redis/LocalStack-S3 — a clean fit for 2 nodes.
  (The `quick-start` chart wants ≥4 distinct `node_group`s — wrong for 2 nodes.)

## 2. Architecture

```
            spark-a2a9 (control-plane, 10.100.8.2)         spark-758e (worker, 10.100.8.1)
            ─────────────── 200GbE NVIDIA-Sync interconnect (enp1s0f1np1) ───────────────
 k3s server  ───────────────────────────────────────────────  k3s agent
 GB10 GPU                                                       GB10 GPU
   │
   ├─ ns osmo-minimal  : gateway(Envoy) → service/worker/logger/agent/router/delayed-job-monitor
   │                     + UI + in-cluster Postgres + Redis + LocalStack-S3
   ├─ ns osmo-operator : backend-listener + backend-worker  (registers cluster as backend "default")
   ├─ ns osmo-workflows: workflow pods (osmo-ctrl + user [+ rsync]) launched per task
   ├─ ns kai-scheduler : KAI gang scheduler
   └─ ns nvidia-device-plugin : GPU device plugin (DaemonSet, both nodes)
```

OSMO tier deployed = **minimal / no-auth** (gateway injects a default admin identity; `oauth2Proxy`
and `authz` disabled). Safe only on a trusted/private network — see §10.

## 3. Prerequisites

- 2× DGX Spark (GB10, aarch64), NVIDIA driver (here 580.159.03), nvidia-container-toolkit, Docker.
- Interconnect up + passwordless SSH between nodes (NVIDIA-Sync sets `~/.ssh` + `/etc/hosts`; reach
  spark-758e at `10.100.8.1`). inotify limits already high.
- Tools (host): `kubectl` 1.36, `helm` 3.20, `jq`, `git`, `curl`. k3s/CLI installed below.
- NGC API key in `~/.ngc/config` + `docker login nvcr.io` (OSMO images are on `nvcr.io/nvidia/osmo`).
- **sudo on each node requires a password → run privileged steps manually.**

## 4. Stage 1 — k3s 2-node cluster  [sudo]
See [`../01-build-k3s-2node.md`](../01-build-k3s-2node.md). Summary:
- **a2a9**: `curl -sfL https://get.k3s.io | sh -s - server --node-ip 10.100.8.2
  --advertise-address 10.100.8.2 --flannel-iface enp1s0f1np1 --node-name spark-a2a9
  --write-kubeconfig-mode 644 --disable traefik` → `sudo cat /var/lib/rancher/k3s/server/node-token`.
- **758e**: `curl ... | INSTALL_K3S_VERSION=v1.35.5+k3s1 K3S_URL=https://10.100.8.2:6443
  K3S_TOKEN=<token> sh -s - agent --node-ip 10.100.8.1 --flannel-iface enp1s0f1np1 --node-name spark-758e`.
- Pinning `--node-ip/--advertise-address/--flannel-iface` to the interconnect avoids the multi-homed
  ambiguity that crash-looped the previous k3s. Then `cp /etc/rancher/k3s/k3s.yaml ~/.kube/config`.

## 5. Stages 2–6 — OSMO layer  [non-sudo, one shot]
Run [`../02-deploy-osmo.sh`](../02-deploy-osmo.sh). It performs, in order:
1. **Namespaces** `osmo-minimal`, `osmo-operator`, `osmo-workflows`.
2. **GPU**: NVIDIA device plugin (`--set runtimeClassName=nvidia`), label both nodes
   `nvidia.com/gpu.present=true node_group=compute`. (k3s already auto-creates the `nvidia` runtimeclass.)
3. **KAI** v0.14.0 via the repo's idempotent `install-kai-scheduler.sh`.
4. **Secrets/MEK** (osmo-minimal): `nvcr-secret` (pull), `db-secret` (`db-password=osmo`),
   `redis-secret` (empty — in-cluster redis is auth-less), `mek-config` (generated JWK).
5. **service chart** with [`../osmo-service-values.yaml`](../osmo-service-values.yaml):
   in-cluster PG/Redis/LocalStack-S3, `storageClassName: local-path` (k3s default), `nodeSelector {}`,
   gateway NodePort 30080, `gateway.defaultIdentity` = admin (minimal no-auth).
6. **CLI** extracted to `~/.local/osmo` + `~/bin/osmo` (userspace, no sudo), then `osmo login`.
7. **backend-operator**: mint token (`osmo token set` for user `backend-operator`/role `osmo-backend`),
   secret `osmo-operator-token`, install with [`../osmo-backend-operator-values.yaml`](../osmo-backend-operator-values.yaml).
8. **Config** ([`../03-configure-osmo.sh`](../03-configure-osmo.sh)): workflow storage (data/log/app →
   LocalStack via cross-namespace FQDN), backend images + nvcr creds, `default_compute` pod template
   (`node_group=compute` + **`runtimeClassName: nvidia`** so GPU pods get the nvidia runtime),
   pool template list, dataset bucket, `service_base_url`, default pool, data credential.

## 6. Verification
```bash
kubectl get nodes -o wide                       # both Sparks Ready, IPs 10.100.8.x
osmo pool list                                  # default ONLINE, GPU capacity = 2
osmo resource list                              # both Sparks, 1 GPU each
osmo workflow submit ../../deployments/workflows/verify-hello.yaml   # CPU  -> COMPLETED
osmo workflow submit ../../deployments/workflows/verify-gpu.yaml     # GPU  -> COMPLETED (nvidia-smi)
curl http://localhost:30080/api/version                              # HTTP 200, 6.3.0
```

## 7. Supported storage backends & control-plane databases

**Object storage** (workflow data/logs/apps/datasets) — pick any S3-compatible or cloud blob:
| Backend | Notes |
|---|---|
| S3-compatible | AWS S3, **MinIO**, **LocalStack** (used here), any S3 API service |
| GCP Google Storage | |
| Azure Blob Storage | |
| Torch Object Storage (TOS) | |

**Control-plane datastore** (not user-selectable — fixed by OSMO):
- **PostgreSQL** (image `postgres:15.1`; schema versioned via pgroll) — state.
- **Redis** (image `redis:7.0`) — cache, job queue (Kombu), event streams, distributed barriers.

Both can be **in-cluster** (this deploy, `postgres.enabled/redis.enabled=true`) or **external/managed**
(set `enabled=false` + point at host; see `deploy_minimal.rst`).

## 8. Operations / maintenance
```bash
# status
kubectl get pods -A | grep -iE 'osmo|kai|nvidia-device'
osmo pool list ; osmo resource list ; osmo workflow list
# upgrade OSMO (re-run with new image tag)
helm upgrade osmo-minimal ../../deployments/charts/service -n osmo-minimal -f ../osmo-service-values.yaml \
  --set global.osmoImageTag=<tag>
# sync upstream OSMO (conflict-free overlay)
git fetch upstream && git merge upstream/main
# teardown OSMO layer (keeps cluster)
helm uninstall osmo-operator -n osmo-operator ; helm uninstall osmo-minimal -n osmo-minimal
kubectl delete ns osmo-minimal osmo-operator osmo-workflows
# full cluster teardown [sudo, each node]
sudo /usr/local/bin/k3s-uninstall.sh       # a2a9 (server)
ssh spark-758e sudo /usr/local/bin/k3s-agent-uninstall.sh
```

## 9. Troubleshooting (issues hit on this build)
- **PVC stuck Pending (`standard` SC)**: chart defaults to `standard`; on k3s set
  `storageClassName: local-path` for postgres/redis/localstackS3 (PVC SC is immutable → delete + reapply).
- **device-plugin DaemonSet 0 pods**: its affinity needs NFD labels → `kubectl label node ...
  nvidia.com/gpu.present=true`.
- **GPU workflow sees no GPU**: workflow pod needs `runtimeClassName: nvidia` (k3s default is runc) —
  set in the `default_compute` pod template.
- **CLI installer needs sudo**: extract the bundle to userspace from the `__ARCHIVE_BELOW__` marker
  (02-deploy-osmo.sh step 7).
- **k3s crash-loop (legacy)**: pin all cluster traffic to the interconnect NIC (see §4).

## 10. Security / production notes
This is the **minimal (no-auth)** tier: the gateway trusts injected identity headers — anyone who can
reach `:30080` is admin. Keep it on a private LAN/VPN. For multi-user/production, move to the full
`deploy_service` path (Keycloak/OAuth + authz sidecar + observability + HA) — on OSMO's Q1-2026 roadmap
as "Simplified Authentication & Authorization".
