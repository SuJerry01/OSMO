# OSMO 本地部署 Runbook — DGX Spark (GB10, aarch64)

這份文件 + 同目錄腳本 = 在這台 DGX Spark 上**清除舊環境 → 全新部署 → 維護** OSMO 的完整、可重跑流程。
依據官方 `docs/deployment_guide/appendix/deploy_local.rst`（KIND/nvkind + `quick-start` chart）。

- **Fork**: https://github.com/SuJerry01/OSMO （`origin`），`upstream` = NVIDIA/OSMO
- **分支**: `spark-local-deploy`
- **本機**: spark-a2a9（control-plane）, GPU = NVIDIA GB10, driver 580.159.03

---

## 為什麼重做

舊環境是用 **`deploy-osmo-minimal.sh` 路線**（namespace `osmo-minimal`/`osmo-operator` + 外部 docker
`osmo-postgres`/`osmo-redis`/`osmo-minio` + local registry，跑在 **k3s** 上），且 **k3s 正在 crash-loop**
（`osmo-proxy` 重啟 1541 次、`osmo-ui` 0/1）。這套與最新官方文件不符，因此**完全重置**改用更乾淨的
**KIND quick-start** 路線。舊狀態快照見 [`_pre_reset_snapshot/`](./_pre_reset_snapshot/)。

> 對照：repo 內有兩條本地路線 ——
> 1. **`deploy_local.rst` → quick-start chart（本 runbook 採用，最簡單、單一 `osmo` namespace）**
> 2. `deployments/scripts/deploy-osmo-minimal.sh`（azure/aws/microk8s/byo，較完整，舊環境用的就是這條）

---

## 架構（quick-start，6 個 KIND 節點）

| 節點 label | 角色 |
|---|---|
| `control-plane` | k8s 控制平面 |
| `node_group=kai-scheduler` | KAI 排程器 |
| `node_group=data` | PostgreSQL / Redis / LocalStack S3 |
| `node_group=service` ×2 | API server、workflow engine、gateway(Envoy)（其一把 NodePort 30080 ↔ host:80） |
| `node_group=compute` | GPU 工作負載（掛 GB10） |

對外：KIND 把 host **port 80** → gateway NodePort，UI 在 `http://quick-start.osmo`（`/etc/hosts` 已有此行）。

---

## 前置工具狀態

| 工具 | 需求 | 本機 |
|---|---|---|
| Docker | ≥28.3.2 | ✅ 29.2.1（default runtime = nvidia）|
| kubectl | ≥1.32.2 | ✅ |
| helm | ≥3.16.2 | ✅ 3.20.1 |
| KIND | ≥0.29.0 | ⬇️ 待裝（`~/bin` → `/usr/local/bin`）|
| Go | (nvkind 需要) | ⬇️ userspace tarball |
| nvkind | latest | ⬇️ `go install` → `/usr/local/bin` |
| nvidia-ctk | — | ✅ 1.19.1 |

---

## 執行順序

> 🔑 標 **[sudo]** 的步驟請看 [`sudo-commands.md`](./sudo-commands.md)，由使用者親自跑。其餘 AI 可代跑。

```
Phase 1  fork + clone（✅ 已完成，就是這個 repo）
Phase 0  pre-flight 快照 + GPU 檢查（✅ 已完成 → _pre_reset_snapshot/）
Phase 2  清除舊環境
         ├─ ./teardown-old.sh                     # 非 sudo：docker 容器 + client config
         └─ [sudo] sudo-commands.md §A             # k3s-uninstall + 舊 CLI + /etc/hosts
Phase 3  裝工具
         ├─ (AI) 裝 Go(userspace) + nvkind + KIND 到 ~/bin、~/go/bin
         ├─ [sudo] sudo-commands.md §C             # cp kind/nvkind 到 /usr/local/bin
         └─ [sudo] sudo-commands.md §B             # inotify sysctl
Phase 4/5  部署 + 驗證
         ├─ ./deploy.sh                            # nvkind 叢集 + gpu-operator + kai + osmo
         ├─ ./verify.sh                            # 節點/pod/UI/login/送 verify-hello workflow
         └─ commit & push 到 fork
```

---

## 維護速查

```bash
# 看狀態
kubectl get pods -n osmo
kubectl get nodes -o wide
nvkind cluster print-gpus

# 升級 OSMO（quick-start chart）
helm repo update && helm upgrade --install osmo osmo/quick-start -n osmo --wait

# 重啟某服務
kubectl rollout restart deploy/<name> -n osmo

# 整個砍掉重來（乾淨）
./teardown-new.sh        # = kind delete cluster --name osmo
./deploy.sh

# 同步官方最新 OSMO
git fetch upstream && git merge upstream/main   # 或 rebase

# 看 log
kubectl logs -n osmo <pod>
kubectl describe pod -n osmo <pod>
```

## 版本（依官方文件 / 本機鎖定）
- GPU Operator: `v25.10.0`
- KAI Scheduler: `v0.12.10`
- OSMO chart: `osmo/quick-start`（latest）/ 鏡像 `nvcr.io/nvidia/osmo`
- 如需 NGC 認證：`~/.ngc` 已存在；必要時 `docker login nvcr.io` 或 helm repo 帶 `$oauthtoken`。

## 已知風險
- **nvkind on ARM64/GB10**：GPU 注入在 ARM 上驗證較少 → 失敗時改用 CPU 版 config（`kind create cluster`）先讓控制平面上線。
- **k3s 移除不可逆**；worker `spark-758e`（另一台機）會孤兒化。
- 其餘 docker 容器（cosmos/isaac/vllm…）、NFS、本機服務**不動**。
