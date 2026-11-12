# homelab

All deployments for my k3s home lab, in one repo.
Cluster-wide setup lives in `cluster/`; each app lives in its own folder under `apps/`.

## Layout

```
cluster/
  setup.sh                    label GPU nodes, install NVIDIA runtime class + device plugin
  nvidia/                     runtimeclass.yaml, device-plugin.yaml
apps/
  llm/                        llama-server + Qwen3.5-4B, OpenAI-compatible API on :8080
    deploy.sh                 deploy / redeploy
    on.sh, off.sh             free the GPU (e.g. for training) and bring it back
    config/model.env          model + server settings (committed)
    .env                      LLAMA_API_KEY (gitignored; copy from .env.example)
    k8s/                      namespace, pvc, deployment, service
  monitoring/                 Prometheus, Loki, Alloy, GPU exporter, Grafana on :3000
    deploy.sh                 deploy / redeploy (no-op when nothing changed)
    .env                      Grafana admin user/password (gitignored; copy from .env.example)
    k8s/                      namespace, HelmCharts (k3s Helm controller), GPU exporter DaemonSet
    dashboards/               custom Grafana dashboards (JSON), provisioned on deploy
    SPEC.md                   what the stack must do and why it's built this way
buildlog/                     notes and evidence for the write-up
```

## Usage

```bash
./cluster/setup.sh            # once, and again whenever nodes change
./apps/llm/deploy.sh          # deploy or redeploy the LLM
./apps/monitoring/deploy.sh   # deploy or redeploy monitoring (reads apps/llm/.env for the scrape key)
```

Aliases (`~/.bashrc`):

```bash
alias llm-on='~/repositories/homelab/apps/llm/on.sh'
alias llm-off='~/repositories/homelab/apps/llm/off.sh'
```

## Adding an app

Create `apps/<name>/` with a `k8s/` folder and a `deploy.sh`. Use its own namespace.
Non-GPU apps need no node rules (see below).

## Node placement

- GPU nodes carry the label `homelab/gpu=true` (set by `cluster/setup.sh`).
- GPU workloads (the LLM, the device plugin) use `nodeSelector: homelab/gpu: "true"`
  and already tolerate the `homelab/gpu` taint.
- To keep everything else off the GPU node, taint it **once there is a second,
  non-GPU node** (with one node it would block all other apps):

  ```bash
  kubectl taint node pablo-ubuntu homelab/gpu=true:NoSchedule
  ```

## Monitoring

| Component | Installed as | What it does |
|---|---|---|
| Prometheus 3 (+ node-exporter, kube-state-metrics) | HelmChart `prometheus` | Metrics, 7 days / 8 GB, scrapes llama-server with the API key |
| nvidia_gpu_exporter | DaemonSet `gpu-exporter` | GPU memory, utilisation, temperature, clocks, power via `nvidia-smi` |
| Loki (single binary) | HelmChart `loki` | Logs, 7 days |
| Grafana Alloy | HelmChart `alloy` (DaemonSet) | Ships container logs from every node, plus Kubernetes events |
| Grafana | HelmChart `grafana` | Dashboards and log search |

Charts are installed by the k3s Helm controller from `HelmChart` objects in `kube-system`
(no Helm CLI). Versions are pinned in each file under `apps/monitoring/k8s/`.

**Access**

- Grafana: `http://<node-ip>:3000`, credentials from `apps/monitoring/.env`.
  Dashboards: *Homelab → LLM + GPU*, and *Community* (Node Exporter Full, Nvidia GPU, Kubernetes views).
- Prometheus and Loki have no auth, so they are not on the LAN:

  ```bash
  kubectl -n monitoring port-forward svc/prometheus-server 9090:80   # http://localhost:9090/targets
  kubectl -n monitoring port-forward svc/loki 3100
  ```

**Checking a deploy.** A successful `kubectl apply` of a HelmChart only means the object was
stored. The install itself runs in a Job:

```bash
kubectl -n kube-system get jobs | grep helm-install
kubectl -n kube-system logs job/helm-install-loki
kubectl -n monitoring get pods
```

**Exporting logs**

- Grafana: *Explore → Loki → run a query → Inspect → Data → Download*.
- `logcli` (with the port-forward above):
  `logcli --addr=http://localhost:3100 query '{namespace="llm"}' --since=24h --limit=0 -o raw > llm.log`
- HTTP API: `curl -G localhost:3100/loki/api/v1/query_range --data-urlencode 'query={namespace="llm"}' --data-urlencode 'limit=5000'`.
  One query returns at most 5000 lines, so page through large ranges by time.

Useful LogQL: `{namespace="llm", container="llama-server"}`, `{job="kubernetes-events"}`.

**Upgrading / removing.** Bump `version:` in a HelmChart file and re-run `deploy.sh`.
Deleting a file from `k8s/` does *not* uninstall anything: `kubectl delete -f <file>` does
(for a HelmChart, that uninstalls the release).

**Notes**

- The GPU exporter does not request `nvidia.com/gpu` (the LLM holds the only GPU). It reads the
  GPU through the NVIDIA runtime, which works while the toolkit setting
  `accept-nvidia-visible-devices-envvar-when-unprivileged` is `true` (the default; see
  `/etc/nvidia-container-runtime/config.toml`).
- The LLM API key is copied into Secret `monitoring/llm-scrape` by `deploy.sh`. After rotating
  the key, re-run both deploy scripts.
- Prometheus and Loki keep data on `local-path` volumes, which are tied to the node they were
  created on. To move them to another node, delete their PVCs and redeploy (≤ 7 days of data lost).
- Grafana has no volume: anything edited in the UI is lost on restart unless exported to
  `apps/monitoring/dashboards/`. Community dashboards are downloaded at pod start (needs internet).

## Prerequisites (GPU node)

1. NVIDIA driver working: `nvidia-smi`
2. NVIDIA Container Toolkit installed (`nvidia-container-toolkit`)
3. k3s installed **after** the toolkit (or `sudo systemctl restart k3s`), so it
   detects the NVIDIA runtime.

## Notes

- No autoscaler: with one GPU a 2nd replica could never schedule. `llm-off`/`llm-on` set
  the replica count, and `deploy.sh` leaves it as is.
- The Deployment uses `Recreate`, because one GPU can't hold the old and new pod at once.
- The first start downloads the image (~2.6 GB) and the model (~2.7 GB); later starts
  load from the PVC.
