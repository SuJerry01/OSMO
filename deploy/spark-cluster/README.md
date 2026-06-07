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

## Stages

| Stage | File | Who | Status |
|---|---|---|---|
| 00 Clean old OSMO/k3s (both boxes) | (done inline; see git history) | sudo | a2a9 ✅ / 758e: run agent-uninstall |
| 01 Build k3s 2-node | [`01-build-k3s-2node.md`](./01-build-k3s-2node.md) | sudo | pending |
| 02 GPU Operator + KAI Scheduler | _tbd_ | AI (helm) | pending |
| 03 Deploy OSMO (`--provider byo`) | _tbd_ | AI (helm/script) | pending |
| 04 Verify (UI + verify-hello workflow) | _tbd_ | AI | pending |

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
