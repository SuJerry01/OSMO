# OSMO User Guide — Dual DGX Spark deployment

How to **use** the OSMO 6.3 instance running on this dual-Spark cluster. Organized from the
official [User Guide](https://nvidia.github.io/OSMO/main/user_guide/) and
[cookbook](https://github.com/NVIDIA/OSMO/tree/main/cookbook), with every example below
**actually run and verified on this cluster**.

> Deployment/architecture/ops → see [`deploy_guide.md`](./deploy_guide.md).

## 1. Access
- **API / UI**: `http://localhost:30080` (gateway NodePort; also reachable at either node IP:30080).
- **CLI**: `~/bin/osmo` (userspace). Login (dev / no-auth tier):
  ```bash
  osmo login http://localhost:30080 --method=dev --username=testuser
  ```
- **Object store (host access)**: LocalStack-S3 NodePort `http://localhost:30035` (S3 API).

## 2. Core concepts
- **Workflow** = a DAG of **tasks** (containers). Tasks declare a **resource** (cpu/mem/gpu/storage)
  and optional **inputs/outputs** (staged via S3). Workflows run on a **pool** of compute backends.
- **Pool** `default` → ONLINE, backed by both Sparks (2 GPU). Scheduling via **KAI** (gang/priority).
- **Data**: per-task `{{output}}`/`{{input:N}}` are auto-staged to/from the workflow S3 bucket;
  `osmo data` is for ad-hoc bucket I/O; **datasets** exist but are **deprecated (6.4)** — prefer buckets.

## 3. CLI quick reference
`osmo` modules: `login workflow app task data dataset credential token bucket resource profile pool user config version`.
```bash
osmo pool list            # pools + GPU capacity
osmo resource list        # nodes in your pool (CPU/Mem/GPU)
osmo workflow submit X.yaml; osmo workflow list; osmo workflow logs <id>; osmo workflow events <id>
osmo workflow exec <id> -t <task> -- bash      # interactive shell into a running task
osmo workflow port-forward <id> ... ; osmo workflow rsync ...
osmo data upload  s3://osmo/<path>/ <local>    # NOTE: remote_uri first, then local
osmo data list/download/delete/check s3://osmo/<path>
osmo config list ; osmo config show <TYPE>     # WORKFLOW/POOL/POD_TEMPLATE/DATASET/SERVICE/...
osmo credential list ; osmo bucket list ; osmo token set ... ; osmo user create ...
```

## 4. Submitting workflows — verified examples
All from `deployments/workflows/` and `cookbook/tutorials/`, run on this cluster:

| Example | Exercises | Result |
|---|---|---|
| `deployments/workflows/verify-hello.yaml` | minimal CPU task | ✅ COMPLETED |
| `deployments/workflows/verify-gpu.yaml` | **1 GPU**, `nvidia-smi` | ✅ COMPLETED |
| `cookbook/tutorials/parallel_tasks.yaml` | parallel tasks | ✅ |
| `cookbook/tutorials/group_tasks.yaml` | **gang scheduling** (KAI PodGroup) | ✅ |
| `cookbook/tutorials/serial_workflow.yaml` | serial deps + **S3 data passing** (`{{output}}`/`{{input:N}}`) | ✅ |
| `cookbook/tutorials/resources_multiple.yaml` | multiple resource classes + GPU | ✅ |
| `cookbook/tutorials/template_hello_world.yaml` | **templates** (`{{var}}`) | ✅ |
| `cookbook/tutorials/data_upload.yaml` | (uses placeholder `s3://my-bucket/`) | edit `outputs.url` to `s3://osmo/...` first |

```bash
osmo workflow submit deployments/workflows/verify-gpu.yaml
osmo workflow logs verify-gpu-1        # -> nvidia-smi shows NVIDIA GB10, CUDA 13.0
```

## 5. Workflow spec features (from the user guide)
Supported in the spec: **resources**, **inputs/outputs**, **templates & tokens**, **barriers**,
**checkpointing**, **exit actions**, **file injection**, **host mounts**, **secrets**, **timeouts**
(`exec_timeout`, `queue_timeout`). Multi-task patterns: serial, parallel, grouped (gang), combination.
See `cookbook/tutorials/` for one YAML per feature, and the
[Workflow spec docs](https://nvidia.github.io/OSMO/main/user_guide/workflows/).

## 6. GPU workflows (important on this cluster)
Request GPU via a resource (`gpu: N`). On k3s the workflow pod **must** use the `nvidia` runtimeclass —
this is already baked into the `default_compute` pod template
(`runtimeClassName: nvidia`, `nodeSelector: node_group=compute`), so any GPU task just works.
Both Sparks are `node_group=compute` (1 GB10 each → 2 GPU total).

## 7. Data
- **In-workflow**: `{{output}}` and `{{input:N}}` stage through the workflow S3 bucket automatically
  (validated by `serial_workflow`). Declare `inputs:`/`outputs:` per task.
- **Ad-hoc (host)**: `osmo data upload s3://osmo/<path>/ <local>` / `download` / `list`. Works from the
  host because the data credential points at the LocalStack NodePort (`http://localhost:30035`, path-style).
- **Datasets**: `osmo dataset ...` works but is **deprecated as of 6.4** and will be removed — use buckets.

## 8. Interactive & apps
- `osmo workflow exec <id> -t <task> -- bash` — shell into a running task (debugging).
- `osmo workflow port-forward` / `osmo workflow rsync` — reach/sync with running tasks.
- `osmo app ...` — package a workflow as a reusable app (`osmo app create/submit`).

## 9. Cookbook (real-world examples)
`cookbook/` has end-to-end recipes relevant to this box: `groot/` (GR00T finetune/mimic/notebook),
`cosmos/`, `dnn_training/` (TorchRun single/multi-node, fault-tolerant), `reinforcement_learning/`
(Isaac Lab), `synthetic_data_generation/` (Isaac Sim), `ros/`, `hil/` (hardware-in-the-loop),
`nims/`, `mobility_gen/`, `nut_pouring/`. Multi-node training maps naturally onto the 2 Sparks.

---

## Appendix A — Feature status on THIS deployment
**Available now** (validated): workflow submit/list/logs/events/cancel, serial/parallel/grouped/combination,
templates/tokens, resources incl. **GPU**, in-cluster **S3 data I/O**, host `osmo data`, pools + KAI
scheduling, apps, interactive exec/port-forward/rsync, config/credential/token/user CLIs.

**Not enabled in this (minimal) tier**: real **authentication/authorization** (gateway injects a default
admin identity — anyone on `:30080` is admin; private-LAN only), multi-tenant RBAC, observability stack
(Prometheus/Grafana/Loki — `podMonitor` off), HA (single replicas). Move to the full `deploy_service`
path for these.

## Appendix B — Supported storage & databases
- **Object storage backends**: S3-compatible (AWS S3, **MinIO**, **LocalStack**=used here), GCP Google
  Storage, Azure Blob, Torch Object Storage (TOS). For LocalStack/MinIO set credential
  `addressing_style: path`.
- **Control-plane datastore** (fixed): **PostgreSQL 15** (state, pgroll-versioned) + **Redis 7** (cache,
  job queue, events, barriers). In-cluster here; can be external/managed.

## Appendix C — Official roadmap (from repo README)
- **Short term (Q1 2026)**: Simplified Auth/Authz (IdP: Azure AD/Okta/Google/OAuth2, `osmo group`,
  pool-level creds); One-Click Cloud Deploy (Azure/AWS Marketplace); Native Cloud Integration (IAM for
  S3/Blob/registry).
- **Long term (2026+)**: Python-Native Workflows; Load-Aware Multi-Backend Scheduling; High-Performance
  Data Caching (Lustre/NFS + object store); Dynamically Changing Workflows (scale running workflows).

## Appendix D — Deprecations
- **Datasets** deprecated as of **6.4**, removed in a future release → use workflow `inputs/outputs` +
  `osmo data` buckets instead. (This deployment runs 6.3; plan migration before upgrading past 6.4.)
