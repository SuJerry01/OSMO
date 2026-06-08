# OSMO on Dual DGX Spark — Production Deploy Runbook

Real **two-node** OSMO deployment across two DGX Sparks (GB10, aarch64), version-controlled.
This is the single source of truth for: **clean up → build cluster → deploy OSMO → maintain.**

- Fork: `SuJerry01/OSMO` (`origin`), `upstream`=NVIDIA/OSMO, branch `spark-local-deploy`
- Nodes: **spark-a2a9** (k3s server / control-plane, `10.100.8.2`) + **spark-758e** (k3s agent, `10.100.8.1`)
- Interconnect: NVIDIA-Sync 200GbE direct link, NIC `enp1s0f1np1`, passwordless SSH (`ssh spark-758e`)
- Both nodes have a GB10 GPU.

## Why this shape (and why NOT KIND/nvkind)

We first tried the official **Local Deployment** (KIND + `nvkind` + quick-start chart, single machine,
simulated nodes). We abandoned it because:
1. **Goal is production + real dual-node**, not single-machine eval with simulated nodes.
2. **nvkind GPU injection failed on this ARM64 box**: KIND 0.32's node runs containerd v2.3.1 with a
   `version=2` config, while `nvidia-ctk` writes a `version=4` drop-in → schema conflict → the compute
   node's containerd won't start. (Reproducible; see git history of the removed `local-spark/` dir.)
3. **Real k3s nodes don't need nvkind** — GPU is attached natively by the **GPU Operator**, which is the
   actual production approach and uses both Sparks.

So: **k3s (real nodes) + GPU Operator + OSMO**, not KIND/nvkind/quick-start.

## Status: ✅ DEPLOYED & VERIFIED (OSMO 6.3.0)

- k3s 2-node cluster (both Sparks Ready, 0 restarts, `node_group=compute`)
- GPU schedulable on both (`nvidia.com/gpu=1` each) via NVIDIA device plugin + `nvidia` runtimeclass
- KAI Scheduler v0.14.0
- OSMO control plane (`osmo-minimal`, 12 pods) + backend-operator (`osmo-operator`, 2 pods)
- Pool `default` **ONLINE**, 2 GPU capacity; storage = in-cluster LocalStack-S3
- **Workflows validated** end-to-end: verify-hello (CPU), verify-gpu (`nvidia-smi`), parallel, gang/KAI, serial+S3 data I/O, templates, host `osmo data` round-trip — all ✅

## Guides
- [`guides/deploy_guide.md`](./guides/deploy_guide.md) — full deploy/architecture/ops/troubleshooting + supported storage & DBs
- [`guides/user_guide.md`](./guides/user_guide.md) — how to use OSMO here (CLI, workflows, GPU, data) + feature status, roadmap, deprecations

## Fixes found during validation (baked into the scripts)
1. `addressing_style: path` on all S3 credentials — LocalStack/MinIO need path-style; without it the bucket
   became a DNS subdomain and **all workflow data I/O failed**. (`03-configure-osmo.sh`)
2. `runtimeClassName: nvidia` in the `default_compute` pod template — k3s GPU pods need it. (`03-configure-osmo.sh`)
3. Host `osmo data` CLI → data credential points at the LocalStack NodePort `http://localhost:30035`. (`03-configure-osmo.sh`)

## Stages

| Stage | File | Who | Status |
|---|---|---|---|
| 00 Clean old OSMO/k3s (both boxes) | git history | sudo | ✅ |
| 01 Build k3s 2-node | [`01-build-k3s-2node.md`](./01-build-k3s-2node.md) | sudo | ✅ |
| 02 OSMO layer (device plugin, KAI, secrets/MEK, service + backend-operator, config) | [`02-deploy-osmo.sh`](./02-deploy-osmo.sh) (non-sudo) | AI | ✅ |
| ├─ service chart values | [`osmo-service-values.yaml`](./osmo-service-values.yaml) | | ✅ |
| ├─ backend-operator values | [`osmo-backend-operator-values.yaml`](./osmo-backend-operator-values.yaml) | | ✅ |
| └─ workflow storage/pool/creds config | [`03-configure-osmo.sh`](./03-configure-osmo.sh) | | ✅ |
| 03 Verify | `osmo workflow submit ../../deployments/workflows/verify-hello.yaml` | AI | ✅ |

## Access
- **API / UI**: `http://localhost:30080` (gateway NodePort 30080; reachable on either node IP too). API check: `curl http://localhost:30080/api/version`.
- **CLI** (userspace, no sudo): `~/bin/osmo` → `~/.local/osmo`. Login: `osmo login http://localhost:30080 --method=dev --username=testuser`.

## Reproduce from scratch
1. **[sudo]** build the cluster — `01-build-k3s-2node.md` (k3s server on a2a9 + agent on 758e over the 10.100.8.x interconnect), then `cp /etc/rancher/k3s/k3s.yaml ~/.kube/config`.
2. **[non-sudo]** `./02-deploy-osmo.sh` — does device-plugin + node labels + KAI + secrets/MEK + service chart + CLI + backend-operator + storage config.
3. Verify: `osmo workflow submit ../../deployments/workflows/verify-hello.yaml && osmo workflow list`.

## OSMO tier (decide at Stage 03)

- **minimal** — no auth (gateway trusts client headers); single-replica; fine for a **private/LAN** cluster.
- **full** (`deploy_service`) — Keycloak/OAuth + authz + observability + HA; for multi-user / exposed.

Both run the same `service` + `backend-operator` charts and support **in-cluster** Postgres/Redis
(`postgres.enabled=true`) — no external managed DB required.

## Maintain (after deploy)
```bash
kubectl get nodes -o wide                  # both Sparks Ready, IPs on 10.100.8.x
kubectl get pods -A | grep -iE 'osmo|gpu|kai'
git fetch upstream && git merge upstream/main   # sync official OSMO, conflict-free overlay
```
