# Sudo 指令清單（請由使用者親自執行）

> 本機 `sudo` 需要密碼，AI 無法非互動執行。以下指令請逐段複製到終端機執行，每段做完把輸出貼回給我。
> 全部指令都針對 **本機 spark-a2a9（k3s control-plane）**。

---

## A. 完全清除舊 OSMO / k3s（破壞性 — Phase 2）

> ⚠️ 這會移除整個 k3s 叢集（含其上所有 osmo-* / gpu-operator / kai-scheduler 工作負載與
> `/var/lib/rancher`、`/etc/rancher`）。執行前我已把舊狀態快照存進
> `deploy/local-spark/_pre_reset_snapshot/`。

```bash
# 1) 移除 k3s（control-plane 本機）
sudo /usr/local/bin/k3s-uninstall.sh

# 2) 移除舊 OSMO CLI（待會用官方 install.sh 重裝）
sudo rm -f /usr/local/bin/osmo
sudo rm -rf /usr/local/osmo

# 3) 清掉 /etc/hosts 裡舊的 registry 那行（保留 quick-start.osmo）
sudo sed -i '/osmo-registry\.spark\.local/d' /etc/hosts
grep -i osmo /etc/hosts        # 確認只剩: 127.0.0.1 quick-start.osmo
```

> 備註：worker 節點 `spark-758e` 是**另一台實體機**，移除本機 control-plane 後它會變孤兒。
> 若要清它，需在那台機器上跑 `sudo /usr/local/bin/k3s-agent-uninstall.sh`（本次範圍外）。

---

## B. 系統設定（KIND 多節點需要 — Phase 2/3）

```bash
# inotify 上限（避免 KIND 多節點 "too many open files"）
echo "fs.inotify.max_user_watches=1048576" | sudo tee -a /etc/sysctl.conf
echo "fs.inotify.max_user_instances=512"   | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## C. 安裝工具到 /usr/local/bin（Phase 3，AI 已先在 userspace 備好二進位）

```bash
# AI 會先把 kind / nvkind 放到 ~/bin 與 ~/go/bin，這裡複製到 PATH
sudo cp ~/bin/kind /usr/local/bin/kind
sudo cp ~/go/bin/nvkind /usr/local/bin/nvkind
kind --version && nvkind --version
```

> 若你不想動 /usr/local/bin，也可改成把 `~/bin` 與 `~/go/bin` 加進 PATH（免 sudo），告訴我即可。

---

## D.（可能需要）CLI 安裝（Phase 5）

`install.sh` 的 Linux 安裝器可能會寫入 `/usr/local/bin`。若它要求 sudo，我會把實際指令貼給你；
通常是：

```bash
curl -fsSL https://raw.githubusercontent.com/NVIDIA/OSMO/refs/heads/main/install.sh | bash
```
