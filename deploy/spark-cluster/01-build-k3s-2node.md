# Build the real 2-node k3s cluster across two DGX Sparks

Production substrate for OSMO on **spark-a2a9** (server/control-plane) + **spark-758e**
(agent/worker), over the NVIDIA-Sync 200GbE interconnect (`enp1s0f1np1`, 10.100.8.0/24).

- a2a9 interconnect IP: `10.100.8.2`  •  758e interconnect IP: `10.100.8.1`
- Both NICs are named `enp1s0f1np1`; both have k3s v1.34.6+k3s1 cached; both have a GB10 GPU.
- The interconnect is pinned explicitly (`--node-ip` / `--advertise-address` / `--flannel-iface`)
  to avoid the multi-homed ambiguity that likely caused the old k3s crash-loop.

> All steps are **sudo** → run by the operator. AI takes over (kubectl/helm/OSMO) once the
> cluster is up and the kubeconfig is readable.

## Step 0 — finish old cleanup (both boxes)
```bash
# on spark-758e
ssh spark-758e
sudo /usr/local/bin/k3s-agent-uninstall.sh
sudo rm -rf /etc/rancher /var/lib/rancher
exit
# on spark-a2a9 (this box)
sudo rm -rf /data/osmo /mnt/osmo-minio /etc/rancher /var/lib/rancher
```

## Step 1 — k3s SERVER on spark-a2a9
```bash
curl -sfL https://get.k3s.io | sh -s - server \
  --node-ip 10.100.8.2 \
  --advertise-address 10.100.8.2 \
  --flannel-iface enp1s0f1np1 \
  --node-name spark-a2a9 \
  --write-kubeconfig-mode 644 \
  --disable traefik
# wait until ready, then grab the join token:
sudo cat /var/lib/rancher/k3s/server/node-token
```
(`--disable traefik`: OSMO ships its own Envoy gateway; we don't want k3s ingress grabbing :80.)

## Step 2 — k3s AGENT on spark-758e (paste the token from Step 1)
```bash
ssh spark-758e
curl -sfL https://get.k3s.io | K3S_URL=https://10.100.8.2:6443 K3S_TOKEN='<PASTE_TOKEN>' \
  sh -s - agent \
  --node-ip 10.100.8.1 \
  --flannel-iface enp1s0f1np1 \
  --node-name spark-758e
exit
```

## Step 3 — hand back to AI (no sudo)
AI then runs on a2a9:
```bash
mkdir -p ~/.kube && cp /etc/rancher/k3s/k3s.yaml ~/.kube/config   # mode 644 → readable
kubectl get nodes -o wide     # expect spark-a2a9 Ready + spark-758e Ready, INTERNAL-IP on 10.100.8.x
```
Then: observe stability (watch a few minutes) → GPU Operator + KAI → OSMO (tier TBD).
